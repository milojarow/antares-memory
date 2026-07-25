#!/usr/bin/env node
// antares "cronista" lobo — headless, ISOLATED (settingSources: []).
// Writes the session JOURNAL (episodic chronicle) from the NEW transcript segment
// (the delta the launcher extracted via the watermark). Runs on PreCompact and
// SessionEnd, chained AHEAD of the destilador in the same launcher. It narrates
// the episode; the destilador distills reusable lessons from the same delta.
// Policy: memory-cronista-prompt.txt. Task (delta path + journal path) on stdin.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { makeScopeGuard } from "./lobo-scope.mjs";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-cronista-prompt.txt"), "utf8");

// stdin — async stream read (readFileSync(0) throws EAGAIN under `printf | node`).
let taskPrompt = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) taskPrompt += chunk;

const model = process.env.ANTARES_CRONISTA_MODEL || "sonnet";
const effort = process.env.ANTARES_CRONISTA_EFFORT || "medium";

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                       // isolated
      systemPrompt: policy,
      // `tools` is the AVAILABILITY filter; `allowedTools` only auto-approves.
      // Without it the lobo runs with the FULL built-in toolset. Probed live:
      // Agent, Bash, Edit, Read, ReportFindings, ScheduleWakeup, Skill,
      // ToolSearch, Workflow, Write — Agent and Workflow being the recursion
      // vectors behind a 101-session fork bomb on one install.
      // Bash stays because it is load-bearing: the lobos append to a journal or
      // changelog with `cat >> file <<EOF` rather than re-reading a large file.
      // Bash REMOVED (2026-07-25). This was the last lobo holding a shell, and the
      // most exposed one: its input is the raw transcript delta, i.e. whatever text
      // passed through a session. It held Bash for one reason — appending to a
      // growing journal without rewriting it, which Read+Write cannot do safely.
      // That reason is gone: it now writes its segment to a fresh file of its own
      // and the LAUNCHER appends it, the same "the lobo proposes, the launcher
      // executes" split this system already uses for deletions. No lobo runs with
      // a shell now.
      tools: ["Read", "Write", "Edit"],
      // NO allowedTools. Bare tool names there ("Write") AUTO-APPROVE every call,
      // so the decision never reaches canUseTool and the scope guard below became a
      // no-op — verified: with it present the lobo wrote outside its scope and the
      // handler was never invoked. Availability is `tools`; the decision is the guard.
      // "default" + canUseTool is the ONLY combination that actually scopes a write
      // here: a path-glob in allowedTools denies even paths INSIDE it, and
      // canUseTool is never called under bypassPermissions. Both probed.
      permissionMode: "default",
      canUseTool: makeScopeGuard("cronista"),
      maxTurns: 15,
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[cronista] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[cronista] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
