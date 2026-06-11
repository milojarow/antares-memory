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
    """Create FTS5 virtual table if it doesn't exist."""
    tables = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_fts'"
    ).fetchone()

    if not tables:
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


def search_v2(conn, query_embedding, query_text, type_filter, top_n,
              vector_w, keyword_w, min_score):
    """Chunk-aware hybrid search with per-file deduplication."""
    type_clause = ""
    params = []
    if type_filter != "all":
        type_clause = "WHERE file_type = ?"
        params.append(type_filter)

    rows = conn.execute(
        f"SELECT id, file_path, chunk_index, content, embedding, title, file_type "
        f"FROM memory_chunks {type_clause}",
        params,
    ).fetchall()

    chunk_data = {}
    for chunk_id, file_path, chunk_idx, content, emb_blob, title, file_type in rows:
        stored = np.frombuffer(emb_blob, dtype=np.float32)
        similarity = max(0.0, min(1.0, float(np.dot(query_embedding, stored))))
        chunk_data[chunk_id] = (similarity, file_path, chunk_idx, content, title, file_type)

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
            spread = worst - best if worst != best else 1.0
            for chunk_id, score in fts_rows:
                bm25_scores[chunk_id] = (worst - score) / spread
    except sqlite3.OperationalError:
        pass

    best_per_file = {}
    for chunk_id in set(chunk_data) | set(bm25_scores):
        if chunk_id not in chunk_data:
            continue

        v_score, file_path, chunk_idx, content, title, file_type = chunk_data[chunk_id]
        k_score = bm25_scores.get(chunk_id, 0.0)
        final = vector_w * v_score + keyword_w * k_score

        if final < min_score:
            continue

        if file_path not in best_per_file or final > best_per_file[file_path][0]:
            snippet = content[:300].replace("\n", " ").strip()
            if len(content) > 300:
                snippet += "..."
            best_per_file[file_path] = (
                final, v_score, k_score, file_path, title, snippet, file_type, chunk_idx
            )

    results = sorted(best_per_file.values(), reverse=True)
    return results[:top_n]


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
            spread = worst - best if worst != best else 1.0
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
        conn = sqlite3.connect(db_path)
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
