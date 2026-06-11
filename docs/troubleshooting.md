# Troubleshooting

Start with `./status.sh` (from the repo clone). It tells you which layer is broken before you go digging.

## Daemon not running

```bash
systemctl --user status antares-memory-daemon
```

| Symptom | Cause | Fix |
|---|---|---|
| `Loaded: not-found` | Unit file missing | Re-run `./install.sh` |
| `Active: failed` | Daemon crashed at startup | `journalctl --user -u antares-memory-daemon -n 50` for the error |
| `Active: active (running)` but no socket | Daemon still loading model | Wait 3–5 seconds and re-check `./status.sh` (from the repo clone) |

Common crash causes:
- `ImportError: sentence_transformers` — venv corrupted or `ANTARES_VENV` env in the unit points wrong. Verify `cat ~/.config/systemd/user/antares-memory-daemon.service`.
- `OOM Killed` — daemon needs ~1.5 GB. If `MemoryMax=1500M` is the cap, the model + index outgrew it. Edit unit to raise.

## Socket exists but ping fails

```bash
echo '{"op":"ping"}' | socat - "UNIX-CONNECT:$XDG_RUNTIME_DIR/memory-search.sock"
```

If no response: stale socket or daemon hung.

```bash
systemctl --user restart antares-memory-daemon
```

If the socket file exists but doesn't connect (`Connection refused`), force-remove it before restart:

```bash
rm -f "$XDG_RUNTIME_DIR/memory-search.sock"
systemctl --user restart antares-memory-daemon
```

## `<auto-loaded-memory>` block isn't appearing

Walk the chain:

1. `./status.sh` (from the repo clone) — is the daemon green?
2. `tail $ANTARES_STATE/logs/memory-search.log` — what's the last entry?
   - `DAEMON_DOWN` → daemon issue (see above)
   - `TIMEOUT` → daemon slow; check `journalctl --user -u antares-memory-daemon`
   - `NOHITS prompt=...` → your prompt didn't match any memory above threshold 0.35
   - `OK timing=...ms hits=N` → memories WERE injected; check Claude Code's view of the session
3. Run a manual search with the same query:
   ```bash
   "$ANTARES_VENV_PY" "$HOME/.claude/scripts/memory-search.py" "your query"
   ```
   If results appear here but not in `<auto-loaded-memory>`, the prompt going through the hook may be different (Claude Code can rewrite prompts; check the actual `prompt` field in the hook input).

## `MEMORY.md` isn't auto-loaded

The system relies on Claude Code's native convention: it loads `~/.claude/projects/<slugify(cwd)>/memory/MEMORY.md`.

If your `MEMORY.md` isn't showing up in the session's system prompt:

1. **Check cwd slug match**:
   ```bash
   echo "cwd: $PWD"
   echo "expected slug: $(echo "$PWD" | tr / -)"
   ls ~/.claude/projects/ | grep "$(echo "$PWD" | tr / -)"
   ```
   If the slug dir doesn't exist for this cwd, the file isn't there. Move or copy `MEMORY.md` to the right slug dir.

2. **Confirm Claude Code version supports this convention**. The native auto-loading of `~/.claude/projects/<slug>/memory/MEMORY.md` is a stable Claude Code behavior. If it doesn't seem to work, sanity-check by inspecting the system prompt of a fresh session — `MEMORY.md` content should appear under a heading like *"Contents of /home/.../memory/MEMORY.md (user's auto-memory, persists across conversations)"*.

3. **Don't add `@~/.claude/...` to your CLAUDE.md unless you're sure the path won't auto-load** — the `@`-import is only for the legacy pre-slug layout or non-standard paths. With the slug layout, it's redundant.

## Memories not being indexed after I add them

The PostToolUse hook runs async. Within ~5 seconds the chunks should appear in the DB:

```bash
sqlite3 ~/.claude/projects/<slug>/memory/.memory-index.db \
  "SELECT COUNT(*) FROM memory_chunks WHERE file_path LIKE '%feedback_my_new_thing%'"
```

If 0:

1. `tail $ANTARES_STATE/logs/memory-reindex-auto.log` — is the hook firing?
2. Confirm the file is `.md` (not `.markdown` or something else).
3. Confirm it's under `~/.claude/projects/<slug>/memory/` (the hook's path matching).

Manual reindex:

```bash
"$ANTARES_VENV_PY" "$HOME/.claude/scripts/memory-index.py" --scope home
# or for a specific cwd:
"$ANTARES_VENV_PY" "$HOME/.claude/scripts/memory-index.py" --scope current --cwd /path
```

## FTS5 missing

If you see `sqlite3.OperationalError: no such module: fts5` in logs, your SQLite build doesn't have FTS5 compiled in.

Linux check:
```bash
sqlite3 :memory: "CREATE VIRTUAL TABLE x USING fts5(a)" && echo OK || echo FAIL
```

If FAIL: install a SQLite build with FTS5. On Arch/Debian/Ubuntu, the default has it. On Alpine you need `sqlite-fts5` (or build from source). On macOS, the system SQLite usually has it; if not, `brew install sqlite` and prepend to PATH.

The daemon will gracefully degrade to **vector-only search** (no BM25) if FTS5 is unavailable — but you lose keyword precision.

## The capture pipeline didn't write any memories

```bash
tail -n 50 "$ANTARES_STATE/logs/memory-chronicle.log"
```

Common log lines (emitted by `memory-chronicle-launch.sh`):

- `INVOKED event=… reason=… session=…` — the launcher fired (PreCompact or SessionEnd).
- `SKIP no transcript` / `SKIP no session_id` — Claude Code didn't supply a transcript or session id; nothing to capture.
- `SKIP reason=resume` — a resumed session is skipped so the same delta isn't re-captured.
- `SKIP nothing new (total=… <= wm=…)` — no transcript lines since the last watermark.
- `SKIP delta trivial (…B)` — the delta is below the size gate; the watermark advances but no lobos spawn (cheap sessions cost nothing).
- `SKIP lock held` — a previous chronicle run for this session is still in flight.
- `LAUNCH chronicle pipeline (background)` — gates passed; cronista + destilador dispatched.
- `CRONISTA rc=… result=…` / `DESTILADOR rc=… result=…` — each lobo's exit. `rc=0` = success; nonzero carries the envelope subtype (`error_max_turns`, or `error_exception` which is usually a transient socket — retried on the next run).
- `watermark advanced -> N` — the session watermark moved forward so the next run only sees newer lines.

To force-trigger a manual capture (testing):

```bash
echo '{"transcript_path":"/path/to/some.jsonl","session_id":"test","hook_event_name":"SessionEnd","cwd":"'"$PWD"'"}' \
  | bash "$HOME/.claude/scripts/memory-chronicle-launch.sh"
```

## Cost-tuning the capture lobos

The capture pipeline (cronista → destilador) and the maintenance lobos (gardener, curator) each read per-lobo env vars — no source edits (deployed scripts get overwritten on re-install). Set them e.g. in `~/.config/environment.d/antares-memory.conf`:

```
# cheaper capture: smaller model + shorter timeout
ANTARES_CRONISTA_MODEL=haiku
ANTARES_DISTILLER_MODEL=haiku
ANTARES_CRONISTA_TIMEOUT=240
ANTARES_DISTILLER_TIMEOUT=300
```

Each lobo honors `ANTARES_<LOBO>_MODEL` / `_EFFORT` / `_TIMEOUT` (`CRONISTA`, `DISTILLER`, `GARDENER`, `CURATOR`). There's no dollar budget cap — the lobos are time-bounded, not cost-bounded.

## Index corrupted / wrong embeddings

If you swapped models without dropping chunks, embeddings are in mixed dimensions and search results will be garbage.

Recover for a given slug:

```bash
DB=~/.claude/projects/<slug>/memory/.memory-index.db
sqlite3 "$DB" "DELETE FROM memory_chunks;"
"$ANTARES_VENV_PY" "$HOME/.claude/scripts/memory-index.py" --scope home   # or --scope current --cwd /path
systemctl --user restart antares-memory-daemon
```

## Multiple sessions, weird state

The daemon is one process for the whole user. If you have 5 Claude Code sessions open across different cwds, they all share it. Each session's `UserPromptSubmit` hook sends its own `cwd` so the daemon resolves the right slugs per query.

If the daemon dies and one session's hook is mid-query, that session gets an empty response (`{}`) and the prompt proceeds without auto-loaded memory.

Restart fixes everything: `systemctl --user restart antares-memory-daemon`.

## After an update, things break

Deployed scripts live in `~/.claude/scripts/` and get refreshed by `./install.sh`. The user's data, venv, and systemd unit live elsewhere and survive any re-deploy.

If an update changes script logic in a way that's incompatible with the existing venv:

```bash
./install.sh   # idempotent — adds missing pieces
```

If the daemon script path ever changes (rare), the systemd unit's `ExecStart` would point at the old script. Re-render the unit:

```bash
./install.sh   # re-runs the template rendering
```
