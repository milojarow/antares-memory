#!/usr/bin/env node
// antares "gardener" lobo — headless maintenance agent (SessionEnd), ISOLATED
// (settingSources: []). Cross-checks the existing memory base for drift that
// per-entry write-time dedup can't catch: near-duplicates, contradictions,
// time-obsolescence. The operator delegated hygiene: it ACTS — merges duplicates
// (Edit survivor) and lists redundant/obsolete files for the launcher to delete
// after a full backup. Conservative; never loses unique content. The lobo itself
// never rm's — it only Edits + Writes a deletions list (policy: memory-gardener-prompt.txt).
//
// Reads its task prompt (which dirs to garden) from stdin. Prints a
// CLI-compatible JSON envelope {result, subtype, total_cost_usd, num_turns}.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { makeScopeGuard } from "./lobo-scope.mjs";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-gardener-prompt.txt"), "utf8");
// stdin — async stream read. readFileSync(0) throws EAGAIN when fd0 is
// non-blocking (intermittent under `printf | node`), so iterate the stream.
let taskPrompt = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) taskPrompt += chunk;

const model = process.env.ANTARES_GARDENER_MODEL || "opus";  // it decides destinies now (merge/remove), not just flags
const effort = process.env.ANTARES_GARDENER_EFFORT || "high";

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                   // isolated: no persona bias while curating
      systemPrompt: policy,
      // `tools` is the AVAILABILITY filter; `allowedTools` only auto-approves.
      // Without it the lobo runs with the FULL built-in toolset. Probed live:
      // Agent, Bash, Edit, Read, ReportFindings, ScheduleWakeup, Skill,
      // ToolSearch, Workflow, Write — Agent and Workflow being the recursion
      // vectors behind a 101-session fork bomb on one install.
      // Bash stays because it is load-bearing: the lobos append to a journal or
      // changelog with `cat >> file <<EOF` rather than re-reading a large file.
      // Bash REMOVED (2026-07-25). This lobo's own policy prompt says
      // verbatim: "you do NOT have a delete tool and you do NOT run shell
      // commands" — handing it Bash contradicted the system prompt it runs under.
      // Its only write targets are the deletions LIST and a changelog, both plain
      // Writes; the launcher validates and executes the deletions. Keeping a shell
      // here bought nothing and cost the widest tool on the box.
      tools: ["Read", "Edit", "Write"],
      // NO allowedTools. Bare tool names there ("Write") AUTO-APPROVE every call,
      // so the decision never reaches canUseTool and the scope guard below became a
      // no-op — verified: with it present the lobo wrote outside its scope and the
      // handler was never invoked. Availability is `tools`; the decision is the guard.
      // "default" + canUseTool is the ONLY combination that actually scopes a write
      // here: a path-glob in allowedTools denies even paths INSIDE it, and
      // canUseTool is never called under bypassPermissions. Both probed.
      permissionMode: "default",
      canUseTool: makeScopeGuard("gardener"),
      maxTurns: 40,                          // triage digest -> merge survivors -> list deletions -> changelog
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[gardener] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[gardener] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
