import type {
  ToolRuntimeContext,
} from "../../_shared/tool-runtime-context.ts";

export async function handleHumanHandoff(
  context: ToolRuntimeContext,
  _args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return {
    status: "ERROR",
    correlation_id: context.correlationId,
    handoff_id: null,
    transfer_mode: "NONE",
    transfer_destination_alias: null,
    allowed_actions: [
      "END_CONVERSATION",
    ],
    error_code: "INTERNAL_ERROR",
    message_for_agent:
      "The human handoff service is not connected yet. Acknowledge the request, avoid claiming a transfer occurred, and end safely.",
    retryable: false,
  };
}