import type {
  TwilioFormParams,
} from "./twilio-signature.ts";


export type TwilioWebhookEventType =
  | "voice_status"
  | "incoming_message"
  | "message_status";


export type ParsedTwilioWebhookEvent =
  | {
      ok: true;

      value: {
        eventType:
          TwilioWebhookEventType;

        providerResourceId:
          string;

        params:
          TwilioFormParams;
      };
    }
  | {
      ok: false;

      errorCode:
        | "EMPTY_BODY"
        | "UNSUPPORTED_EVENT"
        | "INVALID_EVENT";

      message: string;
    };


function firstValue(
  params: TwilioFormParams,
  key: string,
): string | null {
  const value =
    params[key];


  if (typeof value === "string") {
    const trimmed =
      value.trim();

    return trimmed === ""
      ? null
      : trimmed;
  }


  if (
    Array.isArray(value) &&
    value.length > 0
  ) {
    const trimmed =
      value[0].trim();

    return trimmed === ""
      ? null
      : trimmed;
  }


  return null;
}


export function parseTwilioFormBody(
  rawBody: string,
): TwilioFormParams {
  const searchParams =
    new URLSearchParams(
      rawBody,
    );


  const result:
    TwilioFormParams = {};


  for (
    const [
      key,
      value,
    ] of searchParams.entries()
  ) {
    const existing =
      result[key];


    if (existing === undefined) {
      result[key] =
        value;

      continue;
    }


    if (Array.isArray(existing)) {
      existing.push(
        value,
      );

      continue;
    }


    result[key] = [
      existing,
      value,
    ];
  }


  return result;
}


export function parseTwilioWebhookEvent(
  rawBody: string,
):
  ParsedTwilioWebhookEvent {

  if (rawBody.length === 0) {
    return {
      ok: false,
      errorCode:
        "EMPTY_BODY",
      message:
        "Twilio webhook body is empty.",
    };
  }


  const params =
    parseTwilioFormBody(
      rawBody,
    );


  const callSid =
    firstValue(
      params,
      "CallSid",
    );

  const callStatus =
    firstValue(
      params,
      "CallStatus",
    );

  const sequenceNumber =
    firstValue(
      params,
      "SequenceNumber",
    );


  if (
    callSid &&
    callStatus &&
    sequenceNumber !== null
  ) {
    if (
      !/^\d+$/.test(
        sequenceNumber,
      )
    ) {
      return {
        ok: false,
        errorCode:
          "INVALID_EVENT",
        message:
          "Twilio voice status SequenceNumber is invalid.",
      };
    }


    return {
      ok: true,

      value: {
        eventType:
          "voice_status",

        providerResourceId:
          callSid,

        params,
      },
    };
  }


  const messageSid =
    firstValue(
      params,
      "MessageSid",
    );

  const messageStatus =
    firstValue(
      params,
      "MessageStatus",
    );


  // StatusCallback is checked before inbound-message detection because
  // outbound status callbacks may also contain From and To.
  if (
    messageSid &&
    messageStatus
  ) {
    return {
      ok: true,

      value: {
        eventType:
          "message_status",

        providerResourceId:
          messageSid,

        params,
      },
    };
  }


  const from =
    firstValue(
      params,
      "From",
    );

  const to =
    firstValue(
      params,
      "To",
    );


  if (
    messageSid &&
    from &&
    to
  ) {
    return {
      ok: true,

      value: {
        eventType:
          "incoming_message",

        providerResourceId:
          messageSid,

        params,
      },
    };
  }


  return {
    ok: false,
    errorCode:
      "UNSUPPORTED_EVENT",
    message:
      "Webhook does not match a supported Twilio event family.",
  };
}