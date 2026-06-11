# antares-memory

**Persistent semantic + keyword memory for Claude Code — installed as system functionality, not as a plugin.**

Your Claude writes lessons, gotchas, and decisions to disk as `.md` files; a hybrid search daemon (embeddings + BM25) makes them recallable; relevant memories auto-inject into every prompt; and before context is lost — on compaction *and* on session close — isolated headless subagents (the **lobos**) capture what the session learned. It all runs around the model, through hooks: Claude doesn't need to know how it works for it to work.

## Install — tell your Claude

Paste this into a Claude Code session:

> Clone `https://github.com/milojarow/antares-memory` somewhere permanent (e.g. `~/tools/antares-memory` — the clone stays; updates come through it), read its `README.md`, run `./install.sh`, then run `./status.sh` and report the result. Ask me before installing anything outside the listed locations.

The installer is a single idempotent script. It will:

1. Check dependencies (`python3 ≥ 3.10`, `node`, `npm`, `jq`, `socat`, `sqlite3`, `systemctl`, `git`)
2. Create the memory store at `~/.claude/projects/<HOME-slug>/memory/` and seed its `MEMORY.md`
3. Build a Python venv and pre-download the embedding model (~400 MB, one time)
4. Install the Agent SDK once into a stable dir (`~/.local/share/antares-memory/sdk/`)
5. Deploy the system files: hook scripts → `~/.claude/scripts/`, the 4 headless lobos → `~/.claude/agents-sdk/`, the 2 on-demand subagents → `~/.claude/agents/`
6. Merge 5 hook events into `~/.claude/settings.json` (non-destructive — your existing hooks are preserved; a timestamped backup is kept)
7. Install + start the search daemon (systemd user unit pointing at a stable path)
8. Run the first index pass

Then **restart your Claude Code sessions** (hooks are read at session start) and you're live.

**Everything it writes** (so the paste-prompt's boundary is checkable): `~/.claude/scripts/`, `~/.claude/agents-sdk/`, `~/.claude/agents/` (two files), `~/.claude/settings.json` (hook merge + backup), `~/.claude/projects/<HOME-slug>/memory/`, `~/.local/share/antares-memory/` (venv + SDK), `~/.local/state/antares-memory/` (logs, watermarks, backups, deploy manifest), `~/.cache/huggingface/` (the ~400 MB embedding model), `~/.config/systemd/user/antares-memory-daemon.service`. Nothing else, never with sudo.

If a dependency is missing, the installer names all of them at once — install them with your system package manager (that part may need sudo) and re-run `./install.sh`.

### Manual install

```bash
git clone https://github.com/milojarow/antares-memory ~/tools/antares-memory
cd ~/tools/antares-memory
./install.sh
```

### Update

```bash
git -C ~/tools/antares-memory pull && ~/tools/antares-memory/install.sh
```

Re-running the installer **is** the update path: it re-deploys files, re-merges hooks, and restarts the daemon. Nothing else to do.

### Migrating from the old pre-slug layout

If you have memories from an older install living directly under `~/.claude/memory/` (the legacy layout), consolidate them into the slug convention:

```bash
~/tools/antares-memory/migrate.sh            # dry-run: prints the plan
~/tools/antares-memory/migrate.sh --apply
```

### Uninstall

```bash
~/tools/antares-memory/uninstall.sh --yes
```

Removes hooks, deployed files, daemon, venv, SDK, and state. **Never touches your memory files** — those live in Claude Code's own data dir and are yours.

## What you get

| Piece | What it does |
|---|---|
| **Storage** | Flat `.md` files at `~/.claude/projects/<slugify(cwd)>/memory/` — Claude Code's native location. Frontmatter taxonomy: `feedback_*`, `reference_*`, `project_*`, `user_*`, `tool_*` |
| **Auto-recall** | `UserPromptSubmit` hook injects semantically-relevant memories into every prompt (hybrid 70% cosine + 30% BM25, multilingual model kept warm in RAM by a UNIX-socket daemon) |
| **cronista** (lobo) | Only piece that reads the transcript. On PreCompact + SessionEnd, appends the new segment (δ, watermark-tracked) to the session journal |
| **destilador** (lobo) | Reads the cronista's δ and distills durable lessons into memory files, deduping against what exists |
| **gardener** (lobo) | Every ≥24h: merges duplicate memories and **deletes obsolete ones** (tar backup of the whole store first, last 5 kept under the state dir; `MEMORY.md` is never deleted) |
| **curator** (lobo) | Every ≥7d: curates `MEMORY.md`, the always-loaded index |
| **memory-router** (subagent) | On "save this / guarda esto": decides scope (HOME vs project slug) and dedups before writing |
| **memory-recall** (subagent) | On "did we already…?": episodic recall across memories + journals |

The 4 maintenance lobos run headless (Agent SDK, isolated from your persona/config). With a Claude subscription logged in and no `ANTHROPIC_API_KEY` exported, they bill nothing extra; **if `ANTHROPIC_API_KEY` is in the environment, the SDK uses it and every session close bills the key** (gardener/curator default to opus). The 2 subagents dispatch on demand via the Agent tool.

## Why system functionality and not a plugin?

This project shipped as a Claude Code plugin once, and the plugin packaging itself generated a whole family of production bugs: hooks anchored to `${CLAUDE_PLUGIN_ROOT}` break when resumed sessions hold stale versions; per-version cache dirs orphan the SDK's `node_modules`; a systemd unit pointing into a versioned cache path dies on the next update or prune. Infrastructure needs stable paths and deliberate updates. Skills/plugins are the right vehicle for *knowledge the model loads while acting* — not for *machinery that runs around the model*. So: stable locations, hooks in `settings.json`, updates via `git pull && ./install.sh`, and no skill ever loading into context.

## Docs

- [docs/architecture.md](docs/architecture.md) — the 5 layers, end to end
- [docs/lobos-agents-sdk.md](docs/lobos-agents-sdk.md) — the headless lobos: models, gates, locks, envelopes
- [docs/frontmatter-taxonomy.md](docs/frontmatter-taxonomy.md) — memory types and when to use each
- [docs/writing-memories.md](docs/writing-memories.md) — dedup discipline, scope rules, good vs bad memories
- [docs/tuning-search.md](docs/tuning-search.md) — weights, thresholds, switching the embedding model
- [docs/troubleshooting.md](docs/troubleshooting.md) — daemon, FTS5, hooks, recall misses

## Requirements

- Linux with a systemd user instance
- `python3 >= 3.10`, `node` + `npm`, `jq`, `socat`, `sqlite3` (with FTS5), `git`
- ~400 MB disk for the multilingual embedding model
- ~1.5 GB RAM for the daemon (model + index)
- A Claude subscription for the headless lobos (or accept API-key billing — see the note above the "Why" section)

## License

MIT
