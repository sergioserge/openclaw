import { Type } from "@sinclair/typebox";
import { callGateway } from "../../gateway/call.js";
import type { GatewayMessageChannel } from "../../utils/message-channel.js";
import { spawnSubagentDirect } from "../subagent-spawn.js";
import type { AnyAgentTool } from "./common.js";
import { jsonResult, readNumberParam, readStringParam } from "./common.js";
import { readLatestAssistantReply } from "./agent-step.js";

const DEFAULT_TIMEOUT_SECONDS = 120;
// Keep first + last N lines to protect the parent's context window from verbose child output.
const MAX_OUTPUT_LINES_HEAD = 80;
const MAX_OUTPUT_LINES_TAIL = 80;
// Hard char cap after line truncation.
const MAX_OUTPUT_CHARS = 20_000;

function truncateOutput(text: string): string {
  const lines = text.split("\n");
  let truncated = text;
  if (lines.length > MAX_OUTPUT_LINES_HEAD + MAX_OUTPUT_LINES_TAIL) {
    const omitted = lines.length - MAX_OUTPUT_LINES_HEAD - MAX_OUTPUT_LINES_TAIL;
    truncated = [
      ...lines.slice(0, MAX_OUTPUT_LINES_HEAD),
      `...[${omitted} lines omitted]...`,
      ...lines.slice(-MAX_OUTPUT_LINES_TAIL),
    ].join("\n");
  }
  if (truncated.length > MAX_OUTPUT_CHARS) {
    truncated = `${truncated.slice(0, MAX_OUTPUT_CHARS)}...[truncated at ${MAX_OUTPUT_CHARS} chars]`;
  }
  return truncated;
}

const SubagentRunToolSchema = Type.Object({
  task: Type.String({ description: "The self-contained task to delegate to the sub-agent." }),
  timeoutSeconds: Type.Optional(
    Type.Number({
      minimum: 1,
      description: "Max seconds to wait for the child to finish (default 120).",
    }),
  ),
});

export function createSubagentRunTool(opts?: {
  agentSessionKey?: string;
  agentChannel?: GatewayMessageChannel;
  agentAccountId?: string;
  requesterAgentIdOverride?: string;
}): AnyAgentTool {
  return {
    label: "Subagent",
    name: "subagent_run",
    description:
      "Delegate a self-contained task to a fresh child agent that runs synchronously. The child has no memory of previous calls. Blocks until the child finishes and returns its output directly — use this when you need the result inline to continue reasoning.",
    parameters: SubagentRunToolSchema,
    execute: async (_toolCallId, args) => {
      const params = args as Record<string, unknown>;
      const task = readStringParam(params, "task", { required: true });
      const timeoutSeconds =
        readNumberParam(params, "timeoutSeconds") ?? DEFAULT_TIMEOUT_SECONDS;
      const timeoutMs = Math.max(10_000, Math.floor(timeoutSeconds * 1_000));

      // Spawn a fresh isolated child session. expectsCompletionMessage=false suppresses
      // the normal auto-announce because the result is returned via the tool call instead.
      const spawnResult = await spawnSubagentDirect(
        {
          task,
          mode: "run",
          cleanup: "delete",
          expectsCompletionMessage: false,
        },
        {
          agentSessionKey: opts?.agentSessionKey,
          agentChannel: opts?.agentChannel,
          agentAccountId: opts?.agentAccountId,
          requesterAgentIdOverride: opts?.requesterAgentIdOverride,
        },
      );

      if (spawnResult.status !== "accepted" || !spawnResult.runId || !spawnResult.childSessionKey) {
        return jsonResult({
          status: spawnResult.status,
          error: spawnResult.error ?? "Failed to spawn child agent.",
        });
      }

      // Block until the child finishes — synchronous handoff, parent waits.
      const waitResult = await callGateway<{ status?: string }>({
        method: "agent.wait",
        params: { runId: spawnResult.runId, timeoutMs },
        timeoutMs: timeoutMs + 5_000,
      }).catch(() => null);

      if (waitResult?.status !== "ok") {
        return jsonResult({
          status: "timeout",
          runId: spawnResult.runId,
          childSessionKey: spawnResult.childSessionKey,
        });
      }

      // Read the child's final reply and truncate before returning to the parent.
      const reply = await readLatestAssistantReply({
        sessionKey: spawnResult.childSessionKey,
      });
      const output = reply?.trim() ? truncateOutput(reply) : "(no output)";
      return jsonResult({ status: "ok", output });
    },
  };
}
