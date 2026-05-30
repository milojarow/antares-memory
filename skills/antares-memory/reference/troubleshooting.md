# Troubleshooting

Start with `/antares-memory:status`. It tells you which layer is broken before you go digging.

## Daemon not running

```bash
systemctl --user status antares-memory-daemon
```

| Symptom | Cause | Fix |
|---|---|---|
| `Loaded: not-found` | Unit file missing | Re-run `/antares-memory:install` |
| `Active: failed` | Daemon crashed at startup | `journalctl --user -u antares-memory-daemon -n 50` for the error |
| `Active: active (running)` but no socket | Daemon still loading model | Wait 3–5 seconds and re-check `/antares-memory:status` |

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

1. `/antares-memory:status` — is the daemon green?
2. `tail $ANTARES_STATE/logs/memory-search.log` — what's the last entry?
   - `DAEMON_DOWN` → daemon issue (see above)
   - `TIMEOUT` → daemon slow; check `journalctl --user -u antares-memory-daemon`
   - `NOHITS prompt=...` → your prompt didn't match any memory above threshold 0.35
   - `OK timing=...ms hits=N` → memories WERE injected; check Claude Code's view of the session
3. Run a manual search with the same query:
   ```bash
   "$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.py" "your query"
   ```
   If results appear here but not in `<auto-loaded-memory>`, the prompt going through the hook may be different (Claude Code can rewrite prompts; check the actual `prompt` field in the hook input).

## `MEMORY.md` isn't auto-loaded

The skill relies on Claude Code's native convention: it loads `~/.claude/projects/<slugify(cwd)>/memory/MEMORY.md`.

If your `MEMORY.md` isn't showing up in the session's system prompt:

1. **Check cwd slug match**:
   ```bash
   echo "cwd: $PWD"
   echo "expected slug: $(echo "$PWD" | tr / -)"
   ls ~/.claude/projects/ | grep "$(echo "$PWD" | tr / -)"
   ```
   If the slug dir doesn't exist for this cwd, the file isn't there. Move or copy `MEMORY.md` to the right slug dir.

2. **Confirm Claude Code version supports this convention**. The native auto-loading of `~/.claude/projects/<slug>/memory/MEMORY.md` is a stable Claude Code behavior. If it doesn't seem to work, sanity-check by inspecting the system prompt of a fresh session — `MEMORY.md` content should appear under a heading like *"Contents of /home/.../memory/MEMORY.md (user's auto-memory, persists across conversations)"*.

3. **Don't add `@~/.claude/...` to your CLAUDE.md unless you're sure the path won't auto-load** — the `@`-import is for v0.1.x or non-standard paths. With v0.2+ slug layout, it's redundant.

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
"$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.py" --scope home
# or for a specific cwd:
"$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.py" --scope current --cwd /path
```

## FTS5 missing

If you see `sqlite3.OperationalError: no such module: fts5` in logs, your SQLite build doesn't have FTS5 compiled in.

Linux check:
```bash
sqlite3 :memory: "CREATE VIRTUAL TABLE x USING fts5(a)" && echo OK || echo FAIL
```

If FAIL: install a SQLite build with FTS5. On Arch/Debian/Ubuntu, the default has it. On Alpine you need `sqlite-fts5` (or build from source). On macOS, the system SQLite usually has it; if not, `brew install sqlite` and prepend to PATH.

The daemon will gracefully degrade to **vector-only search** (no BM25) if FTS5 is unavailable — but you lose keyword precision.

## PreCompact extractor didn't write any memories

```bash
tail -n 50 "$ANTARES_STATE/logs/memory-precompact.log"
```

Common log lines:

- `SKIP no transcript_path` — Claude Code didn't supply a transcript file. Nothing to extract.
- `SKIP venv not ready` — `/antares-memory:install` wasn't run yet.
- `BUDGET_EXCEEDED` — sub-claude hit the `--max-budget-usd` cap (default $1.00). Partial writes (if any) before the cap are kept. Raise the cap via `ANTARES_PRECOMPACT_BUDGET` env var.
- `TIMEOUT` — sub-claude took > `ANTARES_PRECOMPACT_TIMEOUT` seconds (default 300). Rare; check `cat $XDG_RUNTIME_DIR/antares-memory-precompact-prepared.md | head -50` to see the prepared transcript size.
- `OK turns=N cost=$X` — sub-claude finished, may have written nothing if it judged nothing was worth saving. Look at the `RESULT:` line to see the extraction summary.

To force-trigger a manual capture (testing):

```bash
echo '{"transcript_path":"/path/to/some.jsonl","session_id":"test","hook_event_name":"SessionEnd","cwd":"'"$PWD"'"}' \
  | bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-chronicle-launch.sh"
```

## Cost-tuning the PreCompact extractor

Set env vars (e.g. in `~/.config/environment.d/antares-memory.conf`):

```
ANTARES_PRECOMPACT_BUDGET=0.30
ANTARES_PRECOMPACT_MODEL=haiku
ANTARES_PRECOMPACT_TIMEOUT=180
```

These don't require editing the script (which lives in plugin cache and gets overwritten on update). They're consumed at extractor-spawn time.

## Index corrupted / wrong embeddings

If you swapped models without dropping chunks, embeddings are in mixed dimensions and search results will be garbage.

Recover for a given slug:

```bash
DB=~/.claude/projects/<slug>/memory/.memory-index.db
sqlite3 "$DB" "DELETE FROM memory_chunks;"
"$ANTARES_VENV_PY" "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.py" --scope home   # or --scope current --cwd /path
systemctl --user restart antares-memory-daemon
```

## Multiple sessions, weird state

The daemon is one process for the whole user. If you have 5 Claude Code sessions open across different cwds, they all share it. Each session's `UserPromptSubmit` hook sends its own `cwd` so the daemon resolves the right slugs per query.

If the daemon dies and one session's hook is mid-query, that session gets an empty response (`{}`) and the prompt proceeds without auto-loaded memory.

Restart fixes everything: `systemctl --user restart antares-memory-daemon`.

## After plugin update, things break

The plugin scripts live in `~/.claude/plugins/cache/.../antares-memory-skill/`. Plugin auto-update rebuilds this dir. The user's data, venv, and systemd unit are OUTSIDE this dir, so they survive.

If a plugin update changes script logic in a way that's incompatible with the existing venv:

```bash
/antares-memory:install   # idempotent — adds missing pieces
```

If a plugin update changes the daemon script path (rare), the systemd unit's `ExecStart` still points to the old (now-deleted) script. Re-render the unit:

```bash
/antares-memory:install   # re-runs the template rendering
```
