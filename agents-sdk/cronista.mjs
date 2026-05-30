#!/usr/bin/env node
// antares "cronista" lobo — headless, ISOLATED (settingSources: []).
// Writes the session JOURNAL (episodic chronicle) from the NEW transcript segment
// (the delta the launcher extracted via the watermark). Runs on PreCompact and
// SessionEnd, chained AHEAD of the destilador in the same launcher. It narrates
// the episode; the destilador distills reusable lessons from the same delta.
// Policy: memory-cronista-prompt.txt. Task (delta path + journal path) on stdin.
import { query } from "@anthropic-ai/claude-agent-sdk";
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
      allowedTools: ["Read", "Write", "Edit"],  // Read delta; append to the session journal
      permissionMode: "bypassPermissions",
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
