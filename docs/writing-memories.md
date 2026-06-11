# Writing memories — decision rules

## When TO write a memory

- The operator made a **correction** ("not that, do this instead") — even small ones, with rationale.
- A **tool/API quirk** discovered the hard way (undocumented flags, silent failures, edge cases).
- A **decision with rationale** that a future session could second-guess (architecture choices, library picks, abandoned paths).
- An **environmental fact** (path, version, credential structure, port assignment, service name).
- A **user preference** expressed explicitly ("from now on...", "I prefer...", "always do X").
- A **confirmed approach** the operator accepted without pushback after a non-obvious proposal — these are validated patterns, not corrections.

## When NOT to write a memory

- The pattern is already encoded in code — `git blame` covers that.
- Step-by-step debugging recipes for one-off problems — the fix is in the commit; the *lesson* is what you'd save.
- Restating CLAUDE.md / persona files — they're already loaded.
- "Today we did X" narratives without a portable lesson.
- Anything that would read as obsolete in 60 days.
- The conversation itself — extract, don't transcribe.

**Selectivity target:** 2–6 memories per substantive session. >8 is suspicious — you're probably transcribing.

## HOME vs CURRENT — the decision rule

**HOME** = the slug dir for `$HOME` (`~/.claude/projects/<slugify($HOME)>/memory/`). The lesson applies across multiple cwds. Cross-cutting.

**CURRENT** = the slug dir for the current `$PWD`. The lesson only matters when working in this specific cwd.

When `cwd == $HOME`, HOME and CURRENT are the same dir.

| Memory | Scope | Why |
|---|---|---|
| "API X has an undocumented header requirement" | HOME (`reference_*`) | The API quirk is the same in every project that uses it. |
| "This codebase uses table Y for Z" | CURRENT (`project_*`) | Only true in this cwd. |
| "Operator prefers terse answers" | HOME (`feedback_*`) | Applies everywhere. |
| "Operator wants the deploy script to retry on 502" | CURRENT (`project_*`) | Specific to that deploy pipeline. |
| "Tool `foo` requires Python 3.12 — wheels not on PyPI for 3.13" | HOME (`tool_*`) | Will hit them again in another cwd. |
| "`paru` rejects `--noconfirm` before `-S`" | HOME (`feedback_*`) | Distro-level, every cwd. |

**Rule of thumb for `tool_*`**: if the operator will use this tool/service from *another* cwd too, it's HOME. Cwd-specific configuration of a tool (e.g., "this cwd uses table X for Y") goes CURRENT.

**When in doubt → HOME.** A useful HOME memory occasionally re-appearing in another cwd's search is harmless. A CURRENT memory that should have been HOME is invisible from elsewhere and gets lost.

## Mandatory dedup before writing

For every memory you're about to create:

1. **Grep HOME** by keyword:
   ```bash
   ls ~/.claude/projects/$(echo "$HOME" | tr / -)/memory/ | grep -i <keyword>
   ```
   (Or just `ls ~/.claude/projects/<slugify-of-HOME>/memory/`.)

2. **If CURRENT ≠ HOME**, grep CURRENT too:
   ```bash
   ls ~/.claude/projects/<slugify-of-PWD>/memory/ | grep -i <keyword>
   ```

3. If a similar file exists, **READ** it. Decide:
   - **Enrich** via `Edit` — add a new bullet, expand the rule, refine the example.
   - **Skip** if redundant.
   - **Replace** only if the existing version is wrong.

4. Never create `feedback_X.md` if `feedback_X_v2.md` or a near-synonym exists — `Edit` the original.

## Working in a new cwd for the first time

The slug dir is created lazily. The first time Claude Code runs in a cwd, the slug dir doesn't exist yet. That's fine — Claude Code creates it on demand, and the first time the indexer runs there (SessionStart hook), it gets bootstrapped with an empty DB.

If you want to seed a CURRENT slug with an initial `MEMORY.md`:

```bash
mkdir -p ~/.claude/projects/<slug>/memory
cat > ~/.claude/projects/<slug>/memory/MEMORY.md <<EOF
# Memory — <cwd description>

(initial directives for this cwd)
EOF
```

Once the file exists, Claude Code auto-loads it on every session that opens with that cwd.

## Promoting CURRENT → HOME

If a CURRENT memory turns out to generalize (the same lesson hits in another cwd), promote it:

1. `Edit` the CURRENT file: append a note `→ promoted to HOME as <new-name>`. Leave the file (don't delete) so the cwd's history stays intact.
2. Create the HOME version with the generalized framing (strip cwd-specific examples; keep the core rule).
3. The next reindex picks up both.

## Common writing failures

| Failure | Fix |
|---|---|
| Filename prefix doesn't match `type` | The indexer trusts the prefix for type filtering. Rename OR change `type`. |
| Body is the conversation transcript | Extract the lesson. One paragraph max for the rule, one for the why. |
| `description` is too generic ("things about X") | The description should name the trigger condition specifically — when this memory becomes relevant. |
| Memory has no `Why:` line | Without rationale, future-you can't judge edge cases. Add it. |
| Memory is a 5-step debugging recipe | The recipe goes in the commit message. The *lesson* (the underlying truth) goes in the memory. |
| Two memories that look like duplicates | Run dedup. Either merge or delete one. |
| Wrote to HOME when you meant CURRENT (or vice versa) | `mv` the file to the right slug dir; the PostToolUse hook reindexes both. |

## After writing

The PostToolUse hook auto-reindexes the affected slug async. Within a few seconds, the new memory is searchable. No manual reindex needed.

If the new memory should be **always-loaded** (not just on semantic match), add a one-line pointer to that slug's `MEMORY.md`:

```
- [Title](filename.md) — one-line hook
```

`MEMORY.md` is the curated always-on layer FOR THAT SLUG. Claude Code auto-loads it when cwd matches the slug. Keep it short — it's overhead per prompt while in that cwd.
