#!/usr/bin/env python3
"""Memory search daemon — keeps embedding model in RAM, serves queries over UNIX socket.

Reuses search_v2/search_v1/detect_schema_version from memory-search.py via importlib
(filename has dash, not a valid module name). Each request opens a fresh read-only
SQLite connection so the daemon never locks against memory-index.py reindex runs.
"""

import importlib.util
import json
import os
import signal
import socketserver
import sqlite3
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from common import ANTARES_MODEL, ANTARES_STATE  # noqa: E402

import numpy as np  # noqa: F401, E402

# Load search functions from sibling memory-search.py (filename has dash → use importlib)
_SEARCH_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory-search.py")
_spec = importlib.util.spec_from_file_location("mem_search", _SEARCH_PATH)
_mem_search = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mem_search)

_runtime = os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~/.cache")
SOCKET_PATH = os.path.join(_runtime, "memory-search.sock")

_model = None
_model_lock = threading.Lock()

# Concurrency cap. The server is threaded with no bound, and queries do not
# degrade gracefully when they compete: every thread runs its own full scan of
# the chunk table and the GIL serialises the Python-level scoring loop anyway,
# so they interleave instead of overlapping and each one also evicts the others'
# page cache. Measured: N=1 184ms, N=2 629ms, N=4 2,820ms, N=8 7,533ms with
# majflt 16-26 (no paging involved). Serialising N=8 cleanly would cost
# 8 x 184 = 1,472ms, so unbounded competition is 5.1x more expensive than a
# queue. Meanwhile the caller's budget is 4s: under load the queries did not
# merely slow down, they were killed, and 115 of 2,380 prompts (4.83%) reached
# the model with no memories at all.
#
# Queueing is strictly better than thrashing here. 2 admits the pair that a
# normal prompt produces (global + project scope share one call, but two Claude
# sessions closing together do not) while keeping the tail inside the budget.
_query_sem = threading.BoundedSemaphore(
    int(os.environ.get("ANTARES_MAX_CONCURRENT_QUERIES", "2"))
)


def log(msg):
    print(f"[antares-memory-daemon] {msg}", file=sys.stderr, flush=True)


def get_model():
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                from sentence_transformers import SentenceTransformer
                t0 = time.time()
                _model = SentenceTransformer(ANTARES_MODEL)
                log(f"loaded model {ANTARES_MODEL} in {(time.time()-t0)*1000:.0f}ms "
                    f"(dim={_model.get_sentence_embedding_dimension()})")
    return _model


def _majflt():
    """Major page faults so far — faults that had to go to DISK.

    This is what distinguishes "the query was slow" from "the model was not in
    RAM". The embedding model is ~1 GB and sits idle between prompts, so on a
    memory-pressured host the kernel swaps it out; the next query then pays for
    paging it back in, and from the outside that is indistinguishable from a slow
    search. Measured on this host: 909 MB of the daemon resident set was in swap
    while the p99 query sat at 5.9s against a 4s caller budget.

    A jump here during a query IS the swap-in, measured rather than inferred.
    """
    try:
        with open("/proc/self/stat", "rb") as f:
            # field 12 (1-indexed) is majflt; comm can contain spaces, so split
            # after the closing paren of comm.
            parts = f.read().split(b") ", 1)[1].split()
        return int(parts[9])
    except Exception:
        return -1


def open_db_readonly(db_path):
    return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)


def _do_search_admitted(query, top_k=5, threshold=0.35, types="all",
                        vector_w=0.7, keyword_w=0.3, cwd=None, scope="all"):
    t0 = time.time()

    db_paths = _mem_search.get_db_paths(scope, cwd)
    if not db_paths:
        return {"ok": False, "error": "no_dbs", "scope": scope, "cwd": cwd}

    # Bound the query before it reaches the model. Latency here scales with the
    # LENGTH OF THE PROMPT, not with the size of the corpus, and it does so
    # superlinearly. Measured on this install: 227 chars -> 173ms, 6.8 KB ->
    # 1294ms, 27 KB -> 22142ms.
    #
    # 22 seconds is not a slow query, it is a hook that will be killed: the caller
    # allows 4s. So the prompts that most need memory — a pasted document, a long
    # task notification, an operator dumping a report in — are precisely the ones
    # guaranteed to receive none, and the failure looks identical to "nothing
    # relevant found". Raising the caller's budget cannot fix a 22-second query.
    #
    # Truncating costs nothing: the embedding model reads at most 128 tokens, so
    # everything past that was already discarded for the vector, and keyword
    # matching does not improve past a few hundred terms. Verified on a 7 KB query
    # at caps of 1000/2000/4000/8000 chars — identical top hits at every cap,
    # latency from 2025ms down to 337ms. 4000 leaves any ordinary prompt untouched
    # and bounds the worst case near 600ms.
    max_chars = int(os.environ.get("ANTARES_MAX_QUERY_CHARS", "4000"))
    truncated_from = 0
    if max_chars > 0 and len(query) > max_chars:
        truncated_from = len(query)
        query = query[:max_chars]
        # Logged, never silent: a cap nobody can see is the same class of bug as
        # the timeout it prevents.
        log(f"query truncated {truncated_from} -> {max_chars} chars")

    model = get_model()
    t_enc0 = time.time()
    mf0 = _majflt()
    embedding = model.encode(query, normalize_embeddings=True)
    encode_ms = int((time.time() - t_enc0) * 1000)
    t_db0 = time.time()

    all_hits = []
    schema_versions = {}
    for scope_name, db_path in db_paths:
        try:
            conn = open_db_readonly(db_path)
        except sqlite3.OperationalError as e:
            log(f"could not open {db_path}: {e}")
            continue
        try:
            version = _mem_search.detect_schema_version(conn)
            schema_versions[scope_name] = version
            if version == 2:
                raw_hits = _mem_search.search_v2(
                    conn, embedding, query, types, top_k,
                    vector_w, keyword_w, threshold,
                )
            elif version == 1:
                raw_hits = _mem_search.search_v1(
                    conn, embedding, query, types, top_k,
                    vector_w, keyword_w, threshold,
                )
            else:
                raw_hits = []
            for hit in raw_hits:
                all_hits.append((*hit, scope_name))
        except sqlite3.Error as e:
            # One broken index must not take the healthy ones with it. This block
            # had a `finally` and no `except`, so any DB-level failure in ONE scope
            # propagated out of the loop and discarded the hits already collected
            # from the others. Reproduced: a query that returns 5 hits against the
            # home scope alone returns ZERO when a second, poisoned scope is added.
            # Partial results beat none, and the log says which scope was skipped.
            log(f"scope {scope_name} failed, skipping it: {type(e).__name__}: {e}")
        finally:
            conn.close()

    all_hits.sort(reverse=True)
    all_hits = all_hits[:top_k]

    hits = []
    for final, v_score, k_score, file_path, title, snippet, file_type, chunk_idx, scope_name in all_hits:
        hits.append({
            "score": round(float(final), 3),
            "vec": round(float(v_score), 3),
            "kw": round(float(k_score), 3),
            "path": file_path,
            "title": title,
            "snippet": snippet,
            "type": file_type,
            "chunk": int(chunk_idx),
            "scope": scope_name,
        })

    db_ms = int((time.time() - t_db0) * 1000)
    total_ms = int((time.time() - t0) * 1000)
    mf = _majflt() - mf0 if mf0 >= 0 else -1

    # A slow query is worth a line of its own, with the breakdown that says WHY.
    # Without it, "4019ms" is a number you can only guess at after the fact — and
    # guessing produced two wrong hypotheses before the right one.
    slow_ms = int(os.environ.get("ANTARES_SLOW_QUERY_MS", "1000"))
    if total_ms >= slow_ms:
        # Phases FIRST, major faults only as a tiebreak. Testing `mf > 50` before
        # comparing phases mislabelled 127 of 141 slow queries as swap paging, and
        # 125 of those 127 had db_ms > encode_ms: 81.7% of the time blamed on
        # paging was spent in the DB. The counter does not predict either phase
        # (r(majflt, db_ms) = -0.27, r(majflt, encode_ms) = +0.036), and it cannot:
        # PRAGMA mmap_size = 0, so SQLite reads through pread() and the db phase
        # generates no major faults at all. At ~26 us/fault even the worst burst
        # observed (5,283) is ~137 ms against 1,000-8,000 ms of db time.
        # This line is read by whoever optimises next. It pointed the last audit at
        # the wrong subsystem for an hour.
        cause = ("db search" if db_ms > encode_ms
                 else "paging the model back in from swap" if mf > 50
                 else "encode")
        log(f"SLOW query {total_ms}ms (encode={encode_ms}ms db={db_ms}ms "
            f"majflt={mf} chars={len(query)}) — dominant cost: {cause}")

    return {
        "ok": True,
        "hits": hits,
        "timing_ms": total_ms,
        "encode_ms": encode_ms,
        "db_ms": db_ms,
        "majflt": mf,
        "model": ANTARES_MODEL,
        "db_schemas": schema_versions,
        "scopes_searched": [s for s, _ in db_paths],
    }


def do_search(*args, **kwargs):
    """Admission gate in front of the real search.

    A wrapper rather than a `with` block inside the function body, so the
    hundreds of lines below keep their indentation and their blame history.

    Queue time is logged separately from work time on purpose: the inner t0
    starts after admission, so `timing_ms` keeps meaning "what the search cost"
    and never silently absorbs the wait. The caller's budget covers both, so a
    wait that grows is the thing to watch.
    """
    t_wait = time.time()
    with _query_sem:
        waited_ms = int((time.time() - t_wait) * 1000)
        if waited_ms >= 200:
            log(f"QUEUED {waited_ms}ms waiting for a slot "
                f"(cap={_query_sem._initial_value})")
        resp = _do_search_admitted(*args, **kwargs)
        if isinstance(resp, dict) and waited_ms:
            resp["queued_ms"] = waited_ms
        return resp


class Handler(socketserver.StreamRequestHandler):
    # A client that connects and never writes used to hold a thread forever:
    # rfile.readline() blocks with no deadline. Verified live — one idle
    # connection took the thread count from 28 to 29 and kept it there. With
    # TasksMax=64 that is ~36 stuck connections away from a daemon that answers
    # nothing while the PROCESS stays healthy, which is the worst failure shape
    # available: Restart=always never fires, because nothing died.
    timeout = 10

    def handle(self):
        try:
            line = self.rfile.readline()
            if not line:
                return
            req = json.loads(line.decode("utf-8").strip())
            op = req.get("op", "search")

            if op == "ping":
                resp = {"ok": True, "pong": True, "model": ANTARES_MODEL}
            elif op == "search":
                resp = do_search(
                    query=req.get("query", ""),
                    top_k=int(req.get("top_k", 5)),
                    threshold=float(req.get("threshold", 0.35)),
                    types=req.get("types", "all"),
                    vector_w=float(req.get("vector_weight", 0.7)),
                    keyword_w=float(req.get("keyword_weight", 0.3)),
                    cwd=req.get("cwd") or None,
                    scope=req.get("scope", "all"),
                )
                if resp.get("ok"):
                    log(f"query={req.get('query','')[:80]!r} "
                        f"scopes={resp.get('scopes_searched', [])} "
                        f"hits={len(resp['hits'])} timing={resp['timing_ms']}ms")
            elif op == "shutdown":
                resp = {"ok": True, "shutting_down": True}
                self.wfile.write((json.dumps(resp) + "\n").encode("utf-8"))
                self.wfile.flush()
                self.server._BaseServer__shutdown_request = True
                return
            else:
                resp = {"ok": False, "error": "unknown_op", "op": op}
        except TimeoutError:
            # `timeout` above fired: the client connected and never sent a line.
            # socket.timeout has been an alias of TimeoutError since 3.10. Release
            # the thread silently — there is nobody on the other end to answer, and
            # letting this fall through to the generic handler below would log an
            # error and then try to write into a socket that is going away.
            return
        except json.JSONDecodeError as e:
            resp = {"ok": False, "error": "json_decode", "detail": str(e)}
        except Exception as e:
            log(f"handler error: {type(e).__name__}: {e}")
            resp = {"ok": False, "error": "internal", "detail": f"{type(e).__name__}: {e}"}

        try:
            self.wfile.write((json.dumps(resp) + "\n").encode("utf-8"))
            self.wfile.flush()
        except Exception as e:
            log(f"write error: {e}")


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def remove_stale_socket(path):
    if os.path.exists(path):
        try:
            os.unlink(path)
            log(f"removed stale socket {path}")
        except OSError as e:
            log(f"could not remove socket {path}: {e}")


def main():
    # State dir exists for logs (touched by common.sh but the daemon doesn't
    # source bash, so ensure here too).
    os.makedirs(os.path.join(ANTARES_STATE, "logs"), exist_ok=True)

    remove_stale_socket(SOCKET_PATH)

    # Pre-warm model so first query is fast
    get_model()
    _ = get_model().encode("warmup", normalize_embeddings=True)

    server = ThreadingUnixServer(SOCKET_PATH, Handler)
    os.chmod(SOCKET_PATH, 0o600)
    log(f"listening on {SOCKET_PATH}")

    def shutdown(signum, frame):
        log(f"received signal {signum}, shutting down")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever()
    finally:
        server.server_close()
        remove_stale_socket(SOCKET_PATH)
        log("daemon stopped")


if __name__ == "__main__":
    main()
