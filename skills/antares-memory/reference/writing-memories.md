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

## Global vs project — the decision rule

**Global** (`$CLAUDE_MEMORY_HOME`): the lesson applies across multiple projects. Cross-cutting.

**Project** (`<project_root>/.claude/memory/`): the lesson only matters inside this one codebase.

| Memory | Scope | Why |
|---|---|---|
| "API X has an undocumented header requirement" | global (`reference_*`) | The API quirk is the same in every project that uses it. |
| "This codebase uses table Y for Z" | project (`project_*`) | Only true here. |
| "Operator prefers terse answers" | global (`feedback_*`) | Applies everywhere. |
| "Operator wants the deploy script to retry on 502" | project (`project_*`) | Specific to that deploy pipeline. |
| "Tool `foo` requires Python 3.12 — wheels not on PyPI for 3.13" | global (`tool_*`) | Will hit them again in another project. |
| "`paru` rejects `--noconfirm` before `-S`" | global (`feedback_*`) | Distro-level, every project. |

**Rule of thumb for `tool_*`**: if the operator will use this tool/service in *another* project too, it's GLOBAL. Project-specific configuration of a tool (e.g., "this project uses table X for Y") goes PROJECT.

**When in doubt → global.** A useful global memory occasionally re-appearing in a project search is harmless. A project memory that should have been global is invisible from elsewhere and gets lost.

## Mandatory dedup before writing

For every memory you're about to create:

1. **Grep global** by keyword:
   ```bash
   ls "$CLAUDE_MEMORY_HOME" | grep -i <keyword>
   ```
2. **If in a project**, grep project too:
   ```bash
   ls <project_root>/.claude/memory/ | grep -i <keyword>
   ```
3. If a similar file exists, **READ** it. Decide:
   - **Enrich** via `Edit` — add a new bullet, expand the rule, refine the example.
   - **Skip** if redundant.
   - **Replace** only if the existing version is wrong.
4. Never create `feedback_X.md` if `feedback_X_v2.md` or a near-synonym exists — `Edit` the original.

## Creating a project scope

Project scope is **opt-in**. No script creates `<project>/.claude/memory/` automatically — the operator (or you, when writing the first project-scoped memory) must create it:

```bash
mkdir -p .claude/memory
echo '.claude/memory/' >> .gitignore       # if memories shouldn't be tracked
echo '.claude/memory/.memory-index.db' >> .gitignore   # always — DB is a derivative
```

Once the directory exists:
- `SessionStart` reindex picks it up the next time a session is opened with `cwd` inside the project.
- `UserPromptSubmit` searches both scopes when `cwd` walks up to a `.claude/memory/`.
- `PostToolUse` reindexes the project scope when a `.md` is added/edited under it.

If the directory doesn't exist, the project scope is invisible to all hooks — they silently fall back to global only.

**Should `.claude/memory/` be tracked?** Two answers:
- **Solo project**: track it. The memories are part of the project's institutional knowledge.
- **Client / shared repo**: gitignore. Memories often contain operator commentary, judgments, sensitive context you don't want shared.

## Promoting project → global

If a project memory turns out to generalize (the same lesson hits in another project), promote it:

1. `Edit` the project file: append a note `→ promoted to global as <new-name>`. Leave the file (don't delete) so the project's history stays intact.
2. Create the global version with the generalized framing (strip project-specific examples; keep the core rule).
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

## After writing

The PostToolUse hook auto-reindexes the affected scope async. Within a few seconds, the new memory is searchable. No manual reindex needed.

If the new memory should be **always-loaded** (not just on semantic match), add a one-line pointer to `MEMORY.md`:

```
- [Title](filename.md) — one-line hook
```

`MEMORY.md` is the curated always-on layer. Keep it short — it's loaded into every session's context.
