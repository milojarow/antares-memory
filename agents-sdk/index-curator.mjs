#!/usr/bin/env node
// antares "index-curator" lobo — headless, ISOLATED (settingSources: []).
// OWNS MEMORY.md: decides + APPLIES index promotions/demotions directly (the operator
// delegated index curation — no hand-tending). opus/high. The launcher backs up
// MEMORY.md before each run; the lobo keeps a persistent operator-preferences memory
// and writes a changelog. Conservative on removal (adding is cheap; removing an
// always-on directive can lose something). Policy: memory-curator-prompt.txt. Reads
// its task (digest + prefs + paths) from stdin. Prints a CLI-compatible JSON envelope.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { makeScopeGuard } from "./lobo-scope.mjs";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-curator-prompt.txt"), "utf8");

// stdin — async stream read. readFileSync(0) throws EAGAIN when fd0 is
// non-blocking (intermittent under `printf | node`), so iterate the stream.
let taskPrompt = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) taskPrompt += chunk;

const model = process.env.ANTARES_CURATOR_MODEL || "opus";  // operator delegated index ownership → strongest model
const effort = process.env.ANTARES_CURATOR_EFFORT || "high"; // high-judgment: what stays always-on, what goes

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                          // isolated
      systemPrompt: policy,
      // `tools` is the AVAILABILITY filter; `allowedTools` only auto-approves.
      // Without it the lobo runs with the FULL built-in toolset. Probed live:
      // Agent, Bash, Edit, Read, ReportFindings, ScheduleWakeup, Skill,
      // ToolSearch, Workflow, Write — Agent and Workflow being the recursion
      // vectors behind a 101-session fork bomb on one install.
      // Bash stays because it is load-bearing: the lobos append to a journal or
      // changelog with `cat >> file <<EOF` rather than re-reading a large file.
      // Bash REMOVED (2026-07-25). Zero occurrences of "append" in this
      // lobo's policy prompt: it edits MEMORY.md in place (Edit) and Writes a
      // changelog. Nothing here needs a shell.
      tools: ["Read", "Edit", "Write"],
      // NO allowedTools. Bare tool names there ("Write") AUTO-APPROVE every call,
      // so the decision never reaches canUseTool and the scope guard below became a
      // no-op — verified: with it present the lobo wrote outside its scope and the
      // handler was never invoked. Availability is `tools`; the decision is the guard.
      // "default" + canUseTool is the ONLY combination that actually scopes a write
      // here: a path-glob in allowedTools denies even paths INSIDE it, and
      // canUseTool is never called under bypassPermissions. Both probed.
      permissionMode: "default",
      canUseTool: makeScopeGuard("index-curator"),
      maxTurns: 30, // reads prefs -> decides -> edits MEMORY.md -> changelog -> updates own memory
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[index-curator] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[index-curator] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
