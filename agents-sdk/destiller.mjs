#!/usr/bin/env node
// antares "destilador" lobo — headless, ISOLATED (settingSources: []).
// Turns a session's NEW activity (the delta the cronista just chronicled) into
// reusable MEMORIES. Chained AFTER the cronista in the same launcher, on the same
// delta — so it never re-reads the whole transcript and never duplicates the
// journal. Reconverted from the old PreCompact extractor (which read the whole
// transcript). Policy: memory-distiller-prompt.txt. Task (delta path + memory
// dirs) on stdin. Prints a CLI-compatible JSON envelope.
import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const policy = readFileSync(join(__dir, "..", "scripts", "memory-distiller-prompt.txt"), "utf8");

// stdin — async stream read (readFileSync(0) throws EAGAIN under `printf | node`).
let taskPrompt = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) taskPrompt += chunk;

const model = process.env.ANTARES_DISTILLER_MODEL || "sonnet";
const effort = process.env.ANTARES_DISTILLER_EFFORT || "medium";

let result = "", subtype = "error_unknown", cost = null, turns = null;
try {
  for await (const m of query({
    prompt: taskPrompt,
    options: {
      pathToClaudeCodeExecutable: "claude",
      model,
      effort,
      settingSources: [],                                  // isolated: no persona bias
      systemPrompt: policy,
      allowedTools: ["Read", "Grep", "Glob", "Write", "Edit"], // Read delta + Grep base (dedup) + Write/Edit memories
      permissionMode: "bypassPermissions",
      maxTurns: 30,
    },
  })) {
    if (m.type === "system" && m.subtype === "init") {
      console.error(`[destilador] init apiKeySource=${m.apiKeySource} model=${m.model} effort=${effort}`);
    }
    if (m.type === "result") {
      subtype = m.subtype;
      result = m.result ?? "";
      cost = m.total_cost_usd ?? null;
      turns = m.num_turns ?? null;
    }
  }
} catch (err) {
  console.error(`[destilador] EXCEPTION ${err?.message || err}`);
  subtype = "error_exception";
  result = String(err?.message || err);
}

process.stdout.write(JSON.stringify({ result, subtype, total_cost_usd: cost, num_turns: turns }));
process.exit(subtype === "success" ? 0 : 1);
