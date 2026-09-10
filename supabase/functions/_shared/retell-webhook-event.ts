export const RETELL_WEBHOOK_EVENT_TYPES = [
  "call_started",
  "call_ended",
  "call_analyzed",
] as const;


export type RetellWebhookEventType =
  typeof RETELL_WEBHOOK_EVENT_TYPES[number];


export type RetellWebhookEnvelope = {
  event: RetellWebhookEventType;

  providerCallId: string;

  payload: Record<string, unknown>;
};


export type ParseRetellWebhookEventResult =
  | {
      ok: true;
      value: RetellWebhookEnvelope;
    }
  | {
      ok: false;
      errorCode:
        | "INVALID_JSON"
        | "INVALID_REQUEST"
        | "UNSUPPORTED_EVENT";
      message: string;
    };


function isRecord(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}


function isNonEmptyString(
  value: unknown,
): value is string {
  return (
    typeof value === "string" &&
    value.trim().length > 0
  );
}


function isWebhookEventType(
  value: string,
): value is RetellWebhookEventType {
  return (
    RETELL_WEBHOOK_EVENT_TYPES as readonly string[]
  ).includes(value);
}


export function parseRetellWebhookEvent(
  rawBody: string,
): ParseRetellWebhookEventResult {
  let parsed: unknown;


  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return {
      ok: false,
      errorCode: "INVALID_JSON",
      message:
        "Request body is not valid JSON.",
    };
  }


  if (!isRecord(parsed)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Webhook payload must be a JSON object.",
    };
  }


  if (!isNonEmptyString(parsed.event)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Webhook event type is required.",
    };
  }


  if (!isWebhookEventType(parsed.event)) {
    return {
      ok: false,
      errorCode: "UNSUPPORTED_EVENT",
      message:
        "Webhook event type is not supported.",
    };
  }


  if (!isRecord(parsed.call)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Webhook call object is required.",
    };
  }


  if (!isNonEmptyString(parsed.call.call_id)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Retell call_id is required.",
    };
  }


  return {
    ok: true,

    value: {
      event:
        parsed.event,

      providerCallId:
        parsed.call.call_id,

      payload:
        parsed,
    },
  };
}