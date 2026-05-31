# The internal pack — antares' 6 lobos (Agent SDK)

Antares' judgment points run as **isolated subagents** ("lobos"), not as a bare
`claude -p`. The old `claude -p` extractor loaded your `CLAUDE.md` + persona files
into every run → extraction biased by the operator's voice and inflated token use.
The lobos run with `settingSources: []`, so they see **only** the task you hand
them — no CLAUDE.md, no persona, no auto-memory.

Four lobos run headless through the Claude Agent SDK (cronista, destilador, gardener,
curator); two (router, recall) are filesystem subagents the parent dispatches in-session.

Capture is a pipeline: `transcript ──[cronista]──▶ journal ──[destilador]──▶ memories`.
The cronista reads only the NEW transcript segment (a per-session watermark) and appends
the episodic journal; the destilador then distills durable memories from that same delta.
One watermark → no double-capture between journal and memories. Both run on PreCompact
(compaction = partial close) AND SessionEnd, chained in one fire-and-forget launcher, so
the session is captured even when it never compacts. They replace the old single extractor
that only ran on PreCompact (sessions that closed without compacting were lost).

## The SDK dependency — installed once, stable, survives updates

The headless lobos need `@anthropic-ai/claude-agent-sdk`. It is **not vendored**
(`node_modules/` is gitignored, so it isn't shipped in the plugin). `install.sh`
installs it **once into a stable dir** — `$ANTARES_SDK_DIR` (default
`~/.local/share/antares-memory/sdk`), right next to the Python venv — **not** into
the per-version plugin cache. After `/antares-memory:install` the lobos are ready;
no separate manual step.

**Why stable, not the cache:** the plugin cache lives in a per-version dir
(`.../0.5.7/`). If the SDK lived there, every plugin update would land in a fresh
empty dir and the lobos would silently die with `rc=1` (`ERR_MODULE_NOT_FOUND`).
Installing once in a stable dir (like the venv) makes it update-proof. ESM ignores
`NODE_PATH`, so the launchers can't just point an env var at the stable copy —
instead `antares_link_sdk` (in `lib/common.sh`) symlinks the cache's
`agents-sdk/node_modules` to the stable install right before launching a lobo. That
symlink is recreated for free after every update; the heavy `node_modules` is
installed only once.

**Manual fallback** — only if you skipped the installer or a lobo reports `rc=1`:

```bash
mkdir -p ~/.local/share/antares-memory/sdk && cd "$_"
cp <plugin-cache>/.../antares-memory-skill/agents-sdk/package*.json .
npm ci                       # reproducible install from package-lock.json
# then re-run /antares-memory:install (or just let the next launcher relink it)
```

Verify: `node -e "import('@anthropic-ai/claude-agent-sdk').then(()=>console.log('SDK ok'))"`.

- **Auth** — uses your Claude subscription login (`apiKeySource=none`). Do **not**
  set `ANTHROPIC_API_KEY`; it wins and bills the API. For unattended machines,
  `claude setup-token` → export `CLAUDE_CODE_OAUTH_TOKEN`.
- **Node gotcha** — every `.mjs` passes `pathToClaudeCodeExecutable: "claude"`; the
  bundled binary fails to launch on node ≥24.
- **stdin** — lobos read their task via async stream iteration, not `readFileSync(0)`
  (which throws `EAGAIN` when fd0 is non-blocking under `printf | node`).

## The pack

| Lobo | Runtime | Trigger | Access | Job |
|---|---|---|---|---|
| **cronista** | SDK headless | PreCompact + SessionEnd (bg) | reads the NEW transcript segment (per-session watermark) | appends the episodic **journal** of the session (`journal/session-<id>.md`); produces the δ |
| **destilador** | SDK headless | chained after the cronista (same launcher) | reads the δ + an inline memories digest | distills durable **memories** from the δ, dedup vs the digest — replaces the old extractor / `claude -p` |
| **router** | filesystem agent | dispatched on "save this" / "guarda esto" | reads + writes memories | pick scope (home / project / both / persona) and **dedup semantically** before writing |
| **recall** | filesystem agent | parent dispatches on history questions ("¿ya tratamos X?", "¿qué decidimos?") | read-only (Read/Grep/Glob) | episodic recall — synthesizes what happened / when / decided from memories + journals (on-demand, not the hot path) |
| **gardener** | SDK headless (**opus**) | SessionEnd, gate ≥24h | digest-triage → merges survivors (Edit) → lists redundant files; launcher backs up + deletes | periodic base hygiene: **acts** — consolidates near-dups, removes obsolete (folds unique content into the survivor first); leaves no notes to review |
| **index-curator** | SDK headless (**opus**) | SessionEnd, gate ≥7d | reads digest + its prefs memory, **edits `MEMORY.md`** | OWNS the always-on index: decides + applies promotions/demotions, keeps a persistent operator-preferences memory, backs up `MEMORY.md` first, writes a changelog. Conservative on removal |

Every headless lobo: `settingSources: []` (isolation), `bypassPermissions`, a capped
`maxTurns`, and a fire-and-forget launcher with a frequency **gate** + **lock** so it
never blocks session close nor runs twice at once.

## Scaling: IO in bash, judgment in the LLM

A base with 150+ memories will **time out** a lobo that Reads every body (observed:
the gardener at rc=124 / 300s). So both maintenance launchers (gardener and curator)
pre-digest: bash builds `filename: description` (frontmatter only) for every memory and
passes it **inline** in the task prompt. The lobo triages from text in a few turns and
reads only the handful of files a real candidate needs — no base sweep. Same split as
the old extractor: the agent judges, the shell does the IO. When you add a maintenance lobo
over the whole base, digest first; don't make the model read 150 files.

The curator additionally **owns** `MEMORY.md`: the operator delegated index curation, so
it edits the index directly. Two guardrails make that safe — the launcher backs up
`MEMORY.md` before every run (last 10 kept under `$ANTARES_STATE/memory-md-backups/`),
and the curator reads/writes a persistent preferences memory
(`$ANTARES_STATE/curator-memory.md`) so its taste stays consistent across runs, leaving
a changelog (`.index-changelog.md`) of every change for the operator to audit.

The gardener likewise **acts** instead of annotating — it merges duplicates and removes
obsolete memories. Same delegation, stronger guardrails: the launcher takes a FULL tar
backup of the base before each run (`$ANTARES_STATE/base-backups/`, last 5), the lobo
**never deletes** (it Edits survivors and Writes a deletions list that the launcher
validates + executes — only `.md` inside the memory dir, never `MEMORY.md`), it folds
unique content into the survivor *before* listing a file, and it keeps its own
preferences memory + `.gardener-changelog.md`. The one rule it honors above all: never
lose an important memory — when unsure, KEEP.

## Knobs (env vars — no script edits, survive plugin updates)

Per SDK lobo, `_MODEL` / `_EFFORT` / `_TIMEOUT`: `ANTARES_CRONISTA_*` · `ANTARES_DISTILLER_*`
· `ANTARES_GARDENER_*` · `ANTARES_CURATOR_*`. Defaults: cronista & destilador `sonnet` /
`medium`; **gardener & curator `opus` / `high`** (they make irreversible calls — deleting
files, editing the always-on index). The two filesystem agents (router, recall) take their
model from their `.md` frontmatter, not env vars.

## The one rule when adding a lobo

**Never cascade headless calls.** A headless run that can spawn another headless run
is a fork bomb (the 2026-04-01 incident: 101 sessions / 723 containers in 74 minutes).
Four defenses, always: `settingSources: []`, **no** Agent tool in `allowedTools`,
`CLAUDE_HEADLESS=1` exported, and a capped budget / `maxTurns`. The launchers' gate +
lock are the outer ring of the same defense.
