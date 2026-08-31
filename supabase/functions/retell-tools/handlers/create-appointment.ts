import type {
  ToolRuntimeContext,
} from "../../_shared/tool-runtime-context.ts";

export async function handleCreateAppointment(
  context: ToolRuntimeContext,
  _args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return {
    status: "PROVIDER_ERROR",
    correlation_id: context.correlationId,
    appointment_id: null,
    provider_booking_uid: null,
    start_at: null,
    end_at: null,
    allowed_actions: [
      "REQUEST_HANDOFF",
    ],
    error_code:
      "BOOKING_PROVIDER_UNAVAILABLE",
    message_for_agent:
      "Appointment creation is not connected yet. Do not tell the caller that a booking exists. Offer human follow-up.",
    retryable: false,
  };
}