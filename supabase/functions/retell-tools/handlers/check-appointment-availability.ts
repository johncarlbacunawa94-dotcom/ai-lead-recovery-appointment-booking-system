import type {
  ToolRuntimeContext,
} from "../../_shared/tool-runtime-context.ts";

export async function handleCheckAppointmentAvailability(
  context: ToolRuntimeContext,
  _args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return {
    status: "PROVIDER_ERROR",
    correlation_id: context.correlationId,
    booking_request_id: null,
    resolved_timezone: null,
    slots: [],
    allowed_actions: [
      "REQUEST_HANDOFF",
    ],
    error_code:
      "BOOKING_PROVIDER_UNAVAILABLE",
    message_for_agent:
      "Appointment availability is not connected yet. Do not invent appointment times. Offer human follow-up.",
    retryable: false,
  };
}