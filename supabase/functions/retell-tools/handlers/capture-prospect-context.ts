import type {
  ToolRuntimeContext,
} from "../../_shared/tool-runtime-context.ts";

export async function handleCaptureProspectContext(
  context: ToolRuntimeContext,
  _args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return {
    status: "ERROR",
    correlation_id: context.correlationId,
    prospect_id: null,
    opportunity_id: null,
    identity_resolution:
      "INSUFFICIENT_IDENTITY",
    current_lifecycle_state: null,
    allowed_actions: [
      "REQUEST_HANDOFF",
    ],
    error_code: "INTERNAL_ERROR",
    message_for_agent:
      "Lead context persistence is not available yet. Offer human follow-up instead of claiming the lead was saved.",
    retryable: false,
  };
}