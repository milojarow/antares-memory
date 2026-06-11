# Frontmatter taxonomy

Every memory file is a `.md` with YAML frontmatter. Filename prefix MUST match `type`.

## Schema

```markdown
---
name: <Short imperative title>
description: <One sentence describing what triggers this knowledge>
type: <feedback|reference|project|user|tool>
---

<body — markdown, terse>
```

| Field | Required? | Purpose |
|---|---|---|
| `name` | yes | Human-readable title. Shown in search results. Imperative ("Always do X", "Avoid Y"). |
| `description` | yes | When this memory becomes relevant. Used for human scanning; the embedding sees the full body. |
| `type` | yes | One of the 5 taxonomy values. Determines the filename prefix. |

Optional fields you may see in the wild:
- `originSessionId` — UUID of the session that produced the memory (added by the destilador)

## The 5 types

### `feedback_*.md`

Corrections from the operator, anti-patterns to avoid, validated approaches they confirmed.

**Body structure** (recommended): a sentence stating the rule, then `**Why:**` and `**How to apply:**` lines. The "why" lets you judge edge cases instead of blindly following.

**Example filename:** `feedback_no_latest_tag.md`

```markdown
---
name: Never use `:latest` container tags
description: Container image tags must be pinned by semver or digest. Use when running `podman pull`, writing Dockerfile/Compose files, or configuring Kubernetes manifests.
type: feedback
---

Container images MUST be pinned by semver or digest. Never `image:latest`.

**Why:** `:latest` is mutable — the same tag points to different image bytes over time. Reproducibility dies, rollbacks become impossible, and silent breaking-change updates land in production.

**How to apply:**
- Use `image:1.2.3` for stable pins.
- Use `image@sha256:...` when you absolutely cannot tolerate any drift.
- In Compose, set explicit versions in `image:` keys.
- In Kubernetes, set `imagePullPolicy: IfNotPresent` paired with a semver tag.
```

### `reference_*.md`

Stable technical knowledge — API quirks, format gotchas, undocumented behavior, config schemas.

**Example filename:** `reference_cloudflare_mcp.md`

```markdown
---
name: Cloudflare MCP reference
description: How the cloudflare MCP server authenticates (OAuth) and which operations it covers vs which need the raw REST API (zone creation, account-level ops).
type: reference
---

The `cloudflare` MCP uses OAuth for normal operations (DNS records, Workers, KV).

Zone creation requires the **global API key** (`CLOUDFLARE_GLOBAL_API_KEY`) via direct `curl POST /zones` — the MCP doesn't cover it.

Account-level operations (account creation, billing) also need the global key.
```

### `project_*.md`

State of a specific project — clients, services, ongoing work, who's responsible for what. **Evolves over time** — expect to Edit these.

**Body structure** (recommended): the fact/decision, then `**Why:**` and `**How to apply:**` lines.

**Example filename:** `project_business_context.md`

```markdown
---
name: Business context — 3 companies, shared CRM
description: Operator co-owns 3 companies that share infrastructure. Use when working with the CRM, billing, or any cross-company concern.
type: project
---

The operator co-owns 3 companies — A, B, and C — with their sibling.
They share one self-hosted EspoCRM on a VPS.

**Why:** Decisions about CRM schema, billing, contracts MUST account for cross-company implications.

**How to apply:** Before adding a field/role/team to the CRM, ask whether it should apply across all 3 companies or be scoped to one.
```

### `user_*.md`

Operator's preferences, identity facts, personal context. Rare — most preferences live as `feedback_*` instead.

**Example filename:** `user_communication_style.md`

```markdown
---
name: Operator's preferred communication style
description: How the operator wants answers framed — directness, brevity, dialect preferences.
type: user
---

The operator prefers:
- Spanish neutral (Castilian), NOT rioplatense.
- Short answers — single sentence if it fits.
- No filler openers ("Great question", "I'd be happy to help").
- Direct corrections when they're wrong.
```

### `tool_*.md`

Environment / tool / infra detail. Paths, IDs, credential structures, hostnames, port assignments.

Differs from `reference_*` by being **environment-specific** (this operator's machine, their accounts, their infra) rather than generic technical knowledge.

**Example filename:** `tool_meta_ads_cli.md`

```markdown
---
name: Meta Ads CLI — install + multi-portfolio pattern
description: How the `meta` CLI is installed on this machine and how to run it against multiple ad portfolios.
type: tool
---

Install: `pipx install --python python3.12 meta-ads` (wheels are cp312/cp313 only).

Multi-portfolio pattern: one binary, N working directories `~/work/ads-<client>/` each with their own `.env`. The CLI reads `.env` from $PWD.

Switching clients: `cd ~/work/ads-<client>/` then `meta <command>`.
```

## Naming conventions

After the prefix, use `snake_case`. Be specific.

| Good | Bad |
|---|---|
| `feedback_no_latest_tag.md` | `feedback_docker.md` (too vague) |
| `reference_cloudflare_zone_create_needs_global_key.md` | `reference_cf.md` (cryptic) |
| `tool_meta_ads_cli.md` | `tool_meta.md` (which thing?) |

## What goes in the body

- Lead with the rule/fact/decision.
- Add `**Why:**` so future-you (or another session) can judge edge cases.
- Add `**How to apply:**` with concrete examples.
- Reference related memories with `[[other-memory-name]]` — won't auto-link in the UI, but provides a breadcrumb for future curation.

## What does NOT go in the body

- The conversation that produced the memory (extract the lesson, don't transcribe).
- Restating CLAUDE.md content (that's already loaded).
- Code snippets that exist in the codebase (the code is the source of truth).
- "Today we did X" narratives without a portable lesson.
