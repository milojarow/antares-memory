#!/usr/bin/env python3
"""Hybrid search over the antares-memory store — cosine + BM25, chunk-aware.

Combines semantic similarity (cosine, 70%) with keyword matching (BM25, 30%)
for better results on both conceptual queries and exact name lookups.
Returns the best-scoring chunk per file (deduplication).

Storage model: Claude Code's native slug convention. Each cwd has its own
`~/.claude/projects/<slugify(cwd)>/memory/` dir + `.memory-index.db`.

Scopes:
    home     — slug dir for $HOME (the "global" by convention)
    current  — slug dir for the current $PWD (or --cwd)
    all      — both (default; deduped if same)

Usage:
    memory-search.py "query"
    memory-search.py "eww rounded corners" -n 3
    memory-search.py "systemd path" -t memory
    memory-search.py "tunnel mongo" --scope current --cwd /path/to/proj
"""

import argparse
import os
import sqlite3
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from common import (  # noqa: E402
    ANTARES_MODEL,
    db_path_for,
    home_memory_dir,
    memory_dir_for,
)

import numpy as np  # noqa: E402

VECTOR_WEIGHT = 0.7
KEYWORD_WEIGHT = 0.3
MIN_SCORE = 0.35


def get_db_paths(scope, cwd=None):
    """Return list of (scope_name, db_path) tuples for the requested scope(s).

    Deduped: if current resolves to the same dir as home (cwd == $HOME),
    only one entry is returned.
    """
    cwd = cwd or os.getcwd()
    home_dir = home_memory_dir()
    current_dir = memory_dir_for(cwd)

    paths = []
    seen = set()

    def maybe_add(scope_name, mdir):
        db = db_path_for(mdir)
        if mdir in seen:
            return
        if os.path.exists(db):
            paths.append((scope_name, db))
            seen.add(mdir)

    if scope in ("home", "all"):
        maybe_add("home", home_dir)
    if scope in ("current", "all"):
        if current_dir != home_dir:
            label = f"current:{os.path.basename(os.path.dirname(current_dir))}"
            maybe_add(label, current_dir)

    return paths


def detect_schema_version(conn):
    """Check if DB uses old (file-level) or new (chunk-level) schema."""
    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()]
    if "memory_chunks" in tables:
        return 2
    if "memory_embeddings" in tables:
        return 1
    return 0


def ensure_fts_table(conn, schema_version):
    """Create the FTS5 table if missing. NEVER at the cost of the search.

    This is called from the search path, and the search path's main caller — the
    daemon — opens every index with `mode=ro`. Building the table there raises
    `OperationalError: attempt to write a readonly database`, and because the
    caller never expected a write to happen here, the exception escaped the whole
    query. Measured on one install: 418 of 1385 logged prompts (30%) returned zero
    memories this way, and the operator could not tell it apart from "nothing
    relevant found".

    The state that triggers it is not exotic — an interrupted indexing run leaves
    exactly that shape, because init_db() commits `memory_chunks` before the FTS
    table is created. One killed reindex, and every later search of that scope
    fails until someone reindexes successfully.

    Creating the table is an OPTIMISATION (keyword scoring); the vector half works
    without it, and the FTS query below is already wrapped to degrade. So a failure
    to create is reported, not raised. The indexer, which owns the write
    connection, is what actually builds this table.

    Returns True if keyword search is available.
    """
    tables = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_fts'"
    ).fetchone()
    if tables:
        return True
    try:
        if schema_version == 2:
            conn.execute(
                "CREATE VIRTUAL TABLE memory_fts USING fts5("
                "title, content, content=memory_chunks, content_rowid=id"
                ")"
            )
            conn.execute(
                "INSERT INTO memory_fts(rowid, title, content) "
                "SELECT id, title, content FROM memory_chunks"
            )
        else:
            conn.execute(
                "CREATE VIRTUAL TABLE memory_fts USING fts5("
                "title, content, content=memory_embeddings, content_rowid=rowid"
                ")"
            )
            conn.execute(
                "INSERT INTO memory_fts(rowid, title, content) "
                "SELECT rowid, title, content FROM memory_embeddings"
            )
        conn.commit()
        return True
    except sqlite3.OperationalError:
        # Read-only connection, or another writer holds the DB. Either way this is
        # not the caller's problem to die of: fall back to vector-only.
        return False


def search_v2(conn, query_embedding, query_text, type_filter, top_n,
              vector_w, keyword_w, min_score):
    """Chunk-aware hybrid search with per-file deduplication."""
    type_clause = ""
    params = []
    if type_filter != "all":
        type_clause = "WHERE file_type = ?"
        params.append(type_filter)

    # Scan the ranking columns only, and score with ONE matmul.
    #
    # The old form pulled `content` and `title` for all 17,505 rows on every query
    # — ~4.9 MB of text to use five rows of — and then ran a Python-level np.dot
    # per row. Two costs, one of them shared: the per-row loop holds the GIL, so
    # concurrent queries interleaved instead of overlapping and N=8 took 7.5s each
    # (5.1x worse than serialising). A single `M @ q` releases the GIL and lets
    # BLAS do the whole corpus at once.
    #
    # This is exact, not an approximation: content/title/file_type are hydrated
    # below for the winners only, and nothing before that point reads them —
    # dedup keys on file_path, which is still scanned.
    rows = conn.execute(
        f"SELECT id, file_path, chunk_index, embedding "
        f"FROM memory_chunks {type_clause}",
        params,
    ).fetchall()

    chunk_data = {}
    if rows:
        dim = len(rows[0][3]) // 4  # float32 blobs, width from the data itself
        mat = np.frombuffer(b"".join(r[3] for r in rows),
                            dtype=np.float32).reshape(len(rows), dim)
        sims = np.clip(mat @ np.asarray(query_embedding, dtype=np.float32), 0.0, 1.0)
        for (chunk_id, file_path, chunk_idx, _emb), similarity in zip(rows, sims):
            chunk_data[chunk_id] = (float(similarity), file_path, chunk_idx)

    ensure_fts_table(conn, 2)
    bm25_scores = {}
    try:
        terms = query_text.replace('"', '""').split()
        fts_expr = " OR ".join(f'"{t}"' for t in terms if t.strip())
        if not fts_expr:
            fts_expr = f'"{query_text}"'

        fts_rows = conn.execute(
            "SELECT mc.id, bm25(memory_fts) "
            "FROM memory_fts "
            "JOIN memory_chunks mc ON memory_fts.rowid = mc.id "
            "WHERE memory_fts MATCH ? "
            "ORDER BY bm25(memory_fts)",
            (fts_expr,),
        ).fetchall()

        if fts_rows:
            raw = [s for _, s in fts_rows]
            worst, best = max(raw), min(raw)
            if worst == best:
                # No spread to rank by — which is overwhelmingly the case where a
                # SINGLE chunk matched. Min-max then handed that chunk 0.0, the
                # exact score given to every chunk that did not match the query at
                # all: the keyword half of the ranking went silent precisely on the
                # most discriminating terms, the rare ones that only one memory
                # contains. Measured on this index: of 9,198 terms over five
                # letters, 3,965 — 43% — occur in exactly one chunk, and a query
                # for one of them scored it kw=0.00.
                #
                # With every match tied, the faithful answer is that they all match
                # equally well, not that none of them did.
                for chunk_id, _ in fts_rows:
                    bm25_scores[chunk_id] = 1.0
            else:
                spread = worst - best
                for chunk_id, score in fts_rows:
                    bm25_scores[chunk_id] = (worst - score) / spread
    except sqlite3.OperationalError:
        pass

    best_per_file = {}
    for chunk_id in set(chunk_data) | set(bm25_scores):
        if chunk_id not in chunk_data:
            continue

        v_score, file_path, chunk_idx = chunk_data[chunk_id]
        k_score = bm25_scores.get(chunk_id, 0.0)
        final = vector_w * v_score + keyword_w * k_score

        if final < min_score:
            continue

        if file_path not in best_per_file or final > best_per_file[file_path][0]:
            best_per_file[file_path] = (
                final, v_score, k_score, file_path, chunk_id, chunk_idx
            )

    # Hydrate text for the winners only. Sorting happens after, on the same key
    # order as before (final, v_score, k_score, file_path, ...), and file_path is
    # unique per entry, so no tie can reach the columns that changed shape.
    winners = sorted(best_per_file.values(), reverse=True)[:top_n]
    if not winners:
        return []

    ids = [w[4] for w in winners]
    text_by_id = {
        cid: (content, title, file_type)
        for cid, content, title, file_type in conn.execute(
            "SELECT id, content, title, file_type FROM memory_chunks "
            f"WHERE id IN ({','.join('?' * len(ids))})", ids
        )
    }

    results = []
    for final, v_score, k_score, file_path, chunk_id, chunk_idx in winners:
        content, title, file_type = text_by_id.get(chunk_id, ("", "", ""))
        snippet = content[:300].replace("\n", " ").strip()
        if len(content) > 300:
            snippet += "..."
        results.append(
            (final, v_score, k_score, file_path, title, snippet, file_type, chunk_idx)
        )
    return results


def search_v1(conn, query_embedding, query_text, type_filter, top_n,
              vector_w, keyword_w, min_score):
    """Legacy file-level search (backwards compatibility during migration)."""
    type_clause = ""
    params = []
    if type_filter != "all":
        type_clause = "WHERE file_type = ?"
        params.append(type_filter)

    rows = conn.execute(
        f"SELECT rowid, file_path, content, embedding, title, file_type "
        f"FROM memory_embeddings {type_clause}",
        params,
    ).fetchall()

    vector_scores = {}
    row_data = {}
    for rowid, file_path, content, emb_blob, title, file_type in rows:
        stored = np.frombuffer(emb_blob, dtype=np.float32)
        similarity = max(0.0, min(1.0, float(np.dot(query_embedding, stored))))
        vector_scores[file_path] = similarity
        snippet = content[:200].replace("\n", " ").strip()
        if len(content) > 200:
            snippet += "..."
        row_data[file_path] = (title, snippet, file_type)

    ensure_fts_table(conn, 1)
    bm25_scores = {}
    try:
        terms = query_text.replace('"', '""').split()
        fts_expr = " OR ".join(f'"{t}"' for t in terms if t.strip())
        if not fts_expr:
            fts_expr = f'"{query_text}"'

        fts_rows = conn.execute(
            "SELECT me.file_path, bm25(memory_fts) "
            "FROM memory_fts "
            "JOIN memory_embeddings me ON memory_fts.rowid = me.rowid "
            "WHERE memory_fts MATCH ? "
            "ORDER BY bm25(memory_fts)",
            (fts_expr,),
        ).fetchall()

        if fts_rows:
            raw = [s for _, s in fts_rows]
            worst, best = max(raw), min(raw)
            if worst == best:
                # Same collapse as in search_v2 — see the note there.
                for fp, _ in fts_rows:
                    bm25_scores[fp] = 1.0
            else:
                spread = worst - best
                for fp, score in fts_rows:
                    bm25_scores[fp] = (worst - score) / spread
    except sqlite3.OperationalError:
        pass

    merged = []
    for path in set(vector_scores) | set(bm25_scores):
        v = vector_scores.get(path, 0.0)
        k = bm25_scores.get(path, 0.0)
        final = vector_w * v + keyword_w * k
        if final >= min_score and path in row_data:
            title, snippet, ftype = row_data[path]
            merged.append((final, v, k, path, title, snippet, ftype, 0))

    merged.sort(reverse=True)
    return merged[:top_n]


def main():
    parser = argparse.ArgumentParser(
        description="Hybrid memory search (cosine + BM25, chunk-aware)"
    )
    parser.add_argument("query", help="Search query text")
    parser.add_argument(
        "-n", "--top-n", type=int, default=5, help="Number of results (default: 5)"
    )
    parser.add_argument(
        "-t",
        "--type",
        choices=["memory", "journal", "all"],
        default="all",
        help="Filter by type (default: all)",
    )
    parser.add_argument(
        "-s",
        "--scope",
        default="all",
        choices=["home", "current", "all"],
        help="Search scope (default: all = home + current).",
    )
    parser.add_argument(
        "--cwd",
        default=os.getcwd(),
        help="Working directory used to resolve current scope (default: $PWD).",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=None,
        help=f"Minimum combined score threshold (default: {MIN_SCORE})",
    )
    parser.add_argument(
        "--vector-weight",
        type=float,
        default=None,
        help=f"Weight for cosine similarity (default: {VECTOR_WEIGHT})",
    )
    parser.add_argument(
        "--keyword-weight",
        type=float,
        default=None,
        help=f"Weight for BM25 keyword score (default: {KEYWORD_WEIGHT})",
    )
    args = parser.parse_args()

    vector_w = args.vector_weight if args.vector_weight is not None else VECTOR_WEIGHT
    keyword_w = args.keyword_weight if args.keyword_weight is not None else KEYWORD_WEIGHT
    min_score = args.threshold if args.threshold is not None else MIN_SCORE

    db_paths = get_db_paths(args.scope, args.cwd)
    if not db_paths:
        print(
            f"Error: No memory index found for scope '{args.scope}' (cwd={args.cwd}).",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print(
            "Error: sentence-transformers not installed.\n"
            "Run install.sh to set up the venv.",
            file=sys.stderr,
        )
        sys.exit(1)

    model = SentenceTransformer(ANTARES_MODEL)
    query_embedding = model.encode(args.query, normalize_embeddings=True)

    results = []
    for scope_name, db_path in db_paths:
        # Read-only, like the daemon opens it. A search has no business writing,
        # and this path could: ensure_fts_table() is called from inside both
        # search_v1 and search_v2, and its creation branch runs CREATE VIRTUAL
        # TABLE + INSERT..SELECT + commit. Inert while the table exists, but it is
        # a write that can take the lock against a running memory-index.py. The
        # function already degrades to vector-only on OperationalError, which is
        # exactly what a read-only handle raises.
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        version = detect_schema_version(conn)

        if version == 2:
            hits = search_v2(conn, query_embedding, args.query, args.type, args.top_n,
                             vector_w, keyword_w, min_score)
        elif version == 1:
            hits = search_v1(conn, query_embedding, args.query, args.type, args.top_n,
                             vector_w, keyword_w, min_score)
        else:
            hits = []

        for hit in hits:
            results.append((*hit, scope_name))
        conn.close()

    results.sort(reverse=True)
    results = results[: args.top_n]

    if not results:
        print("No relevant memories found.")
        sys.exit(0)

    for final, v_score, k_score, path, title, snippet, ftype, chunk_idx, scope_name in results:
        chunk_label = f" chunk:{chunk_idx}" if chunk_idx > 0 else ""
        print(f"[{final:.3f}] (vec:{v_score:.2f} kw:{k_score:.2f}) [{scope_name}/{ftype}{chunk_label}] {title}")
        print(f"  File: {path}")
        print(f"  {snippet}")
        print()


if __name__ == "__main__":
    main()
