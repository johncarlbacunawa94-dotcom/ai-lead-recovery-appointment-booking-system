export const RETELL_TOOL_NAMES = [
  "capture_prospect_context_v1",
  "correct_primary_email_v1",
  "check_appointment_availability_v1",
  "create_appointment_v1",
  "request_human_handoff_v1",
] as const;


export const RETELL_CALL_STATUSES = [
  "registered",
  "not_connected",
  "ongoing",
  "ended",
  "error",
] as const;


export type RetellToolName =
  typeof RETELL_TOOL_NAMES[number];


export type RetellCallStatus =
  typeof RETELL_CALL_STATUSES[number];


export type RetellCallContext = {
  call_id: string;

  call_type:
    | "web_call"
    | "phone_call";

  call_status?: RetellCallStatus;

  agent_id?: string;

  agent_version?: number;

  direction?:
    | "inbound"
    | "outbound";

  start_timestamp?: number;
};


export type RetellToolEnvelope = {
  name: RetellToolName;

  call: RetellCallContext;

  args: Record<string, unknown>;
};


export type ParseEnvelopeResult =
  | {
      ok: true;
      value: RetellToolEnvelope;
    }
  | {
      ok: false;
      errorCode:
        | "INVALID_JSON"
        | "INVALID_REQUEST"
        | "UNSUPPORTED_TOOL";
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


function isToolName(
  value: string,
): value is RetellToolName {
  return (
    RETELL_TOOL_NAMES as readonly string[]
  ).includes(value);
}


function isCallStatus(
  value: string,
): value is RetellCallStatus {
  return (
    RETELL_CALL_STATUSES as readonly string[]
  ).includes(value);
}


export function parseRetellToolEnvelope(
  rawBody: string,
): ParseEnvelopeResult {
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
        "Request body must be an object.",
    };
  }


  if (!isNonEmptyString(parsed.name)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Function name is required.",
    };
  }


  if (!isToolName(parsed.name)) {
    return {
      ok: false,
      errorCode: "UNSUPPORTED_TOOL",
      message:
        "Function name is not supported.",
    };
  }


  if (!isRecord(parsed.call)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Retell call context is required.",
    };
  }


  if (
    !isNonEmptyString(
      parsed.call.call_id,
    )
  ) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Retell call_id is required.",
    };
  }


  if (
    parsed.call.call_type !==
      "web_call" &&
    parsed.call.call_type !==
      "phone_call"
  ) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Retell call_type is invalid.",
    };
  }


  if (
    parsed.call.call_status !==
      undefined
  ) {
    if (
      !isNonEmptyString(
        parsed.call.call_status,
      ) ||
      !isCallStatus(
        parsed.call.call_status,
      )
    ) {
      return {
        ok: false,
        errorCode:
          "INVALID_REQUEST",
        message:
          "Retell call_status is invalid.",
      };
    }
  }


  if (
    parsed.call.start_timestamp !==
      undefined
  ) {
    if (
      typeof
        parsed.call.start_timestamp !==
          "number" ||
      !Number.isSafeInteger(
        parsed.call.start_timestamp,
      ) ||
      parsed.call.start_timestamp < 0
    ) {
      return {
        ok: false,
        errorCode:
          "INVALID_REQUEST",
        message:
          "Retell start_timestamp is invalid.",
      };
    }
  }


  if (!isRecord(parsed.args)) {
    return {
      ok: false,
      errorCode: "INVALID_REQUEST",
      message:
        "Function args must be an object.",
    };
  }


  const call: RetellCallContext = {
    call_id:
      parsed.call.call_id,

    call_type:
      parsed.call.call_type,
  };


  if (
    typeof
      parsed.call.call_status ===
        "string" &&
    isCallStatus(
      parsed.call.call_status,
    )
  ) {
    call.call_status =
      parsed.call.call_status;
  }


  if (
    isNonEmptyString(
      parsed.call.agent_id,
    )
  ) {
    call.agent_id =
      parsed.call.agent_id;
  }


  if (
    typeof
      parsed.call.agent_version ===
        "number" &&
    Number.isInteger(
      parsed.call.agent_version,
    )
  ) {
    call.agent_version =
      parsed.call.agent_version;
  }


  if (
    parsed.call.direction ===
      "inbound" ||
    parsed.call.direction ===
      "outbound"
  ) {
    call.direction =
      parsed.call.direction;
  }


  if (
    typeof
      parsed.call.start_timestamp ===
        "number"
  ) {
    call.start_timestamp =
      parsed.call.start_timestamp;
  }


  return {
    ok: true,

    value: {
      name:
        parsed.name,

      call,

      args:
        parsed.args,
    },
  };
}