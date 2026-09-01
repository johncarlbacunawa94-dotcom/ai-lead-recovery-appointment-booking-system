import type {
  SupabaseClient,
} from "npm:@supabase/supabase-js@^2";


export type ToolExecutionOutcome =
  | "PENDING"
  | "SUCCEEDED"
  | "FAILED"
  | "REPLAYED"
  | "REJECTED";


export type ToolExecutionRecord = {
  tool_execution_id: string;
  correlation_id: string;

  request_hash: string;

  outcome:
    ToolExecutionOutcome;

  response_payload:
    | Record<string, unknown>
    | null;
};


export type AcquireToolExecutionResult =
  | {
      ok: true;

      record: ToolExecutionRecord;

      cachedResponse:
        | Record<string, unknown>
        | null;

      replay: boolean;

      ownsExecution: boolean;
    }
  | {
      ok: false;

      errorCode:
        | "IDEMPOTENCY_CONFLICT"
        | "IDEMPOTENCY_PENDING_TIMEOUT"
        | "INTERNAL_ERROR";
    };


const TERMINAL_OUTCOMES =
  new Set<ToolExecutionOutcome>([
    "SUCCEEDED",
    "FAILED",
    "REJECTED",
    "REPLAYED",
  ]);


const REPLAY_WAIT_TIMEOUT_MS =
  5000;


const REPLAY_POLL_INTERVAL_MS =
  50;


function isRecord(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}


function stableValue(
  value: unknown,
): unknown {

  if (Array.isArray(value)) {
    return value.map(
      stableValue,
    );
  }


  if (isRecord(value)) {
    const result:
      Record<string, unknown> = {};

    for (
      const key of
      Object.keys(value).sort()
    ) {
      result[key] =
        stableValue(
          value[key],
        );
    }

    return result;
  }


  return value;
}


export function stableJson(
  value: unknown,
): string {
  return JSON.stringify(
    stableValue(value),
  );
}


function sleep(
  milliseconds: number,
): Promise<void> {
  return new Promise(
    (resolve) => {
      setTimeout(
        resolve,
        milliseconds,
      );
    },
  );
}


async function sha256Hex(
  value: string,
): Promise<string> {

  const bytes =
    new TextEncoder()
      .encode(value);


  const digest =
    await crypto.subtle.digest(
      "SHA-256",
      bytes,
    );


  return Array.from(
    new Uint8Array(digest),
  )
    .map(
      (byte) =>
        byte
          .toString(16)
          .padStart(2, "0"),
    )
    .join("");
}


export async function buildToolRequestIdentity(
  providerCallId: string,
  toolName: string,
  normalizedArguments:
    Record<string, unknown>,
): Promise<{
  requestHash: string;
  idempotencyKey: string;
}> {

  const requestHash =
    await sha256Hex(
      stableJson(
        normalizedArguments,
      ),
    );


  const idempotencyKey =
    await sha256Hex(
      [
        "RETELL_TOOL_V1",
        providerCallId,
        toolName,
        requestHash,
      ].join("\n"),
    );


  return {
    requestHash,
    idempotencyKey,
  };
}


async function readToolExecution(
  supabaseAdmin: SupabaseClient,
  idempotencyKey: string,
): Promise<
  ToolExecutionRecord | null
> {

  const {
    data,
    error,
  } = await supabaseAdmin
    .from("tool_executions")
    .select(
      [
        "tool_execution_id",
        "correlation_id",
        "request_hash",
        "outcome",
        "response_payload",
      ].join(","),
    )
    .eq(
      "idempotency_key",
      idempotencyKey,
    )
    .single();


  if (
    error ||
    !data
  ) {
    return null;
  }


  return (
    data as ToolExecutionRecord
  );
}


async function waitForTerminalExecution(
  supabaseAdmin: SupabaseClient,

  input: {
    idempotencyKey: string;
    requestHash: string;
  },
): Promise<
  | {
      ok: true;

      record:
        ToolExecutionRecord;

      cachedResponse:
        Record<string, unknown>;
    }
  | {
      ok: false;

      errorCode:
        | "IDEMPOTENCY_CONFLICT"
        | "IDEMPOTENCY_PENDING_TIMEOUT"
        | "INTERNAL_ERROR";
    }
> {

  const deadline =
    Date.now() +
    REPLAY_WAIT_TIMEOUT_MS;


  while (
    Date.now() <
      deadline
  ) {

    const record =
      await readToolExecution(
        supabaseAdmin,
        input.idempotencyKey,
      );


    if (!record) {
      return {
        ok: false,
        errorCode:
          "INTERNAL_ERROR",
      };
    }


    if (
      record.request_hash !==
        input.requestHash
    ) {
      return {
        ok: false,
        errorCode:
          "IDEMPOTENCY_CONFLICT",
      };
    }


    if (
      TERMINAL_OUTCOMES.has(
        record.outcome,
      )
    ) {

      if (
        !isRecord(
          record.response_payload,
        )
      ) {
        return {
          ok: false,
          errorCode:
            "INTERNAL_ERROR",
        };
      }


      return {
        ok: true,

        record,

        cachedResponse:
          record.response_payload,
      };
    }


    await sleep(
      REPLAY_POLL_INTERVAL_MS,
    );
  }


  return {
    ok: false,
    errorCode:
      "IDEMPOTENCY_PENDING_TIMEOUT",
  };
}


export async function acquireToolExecution(
  supabaseAdmin: SupabaseClient,

  input: {
    canonicalCallId: string;
    providerCallId: string;

    toolName: string;

    requestHash: string;
    idempotencyKey: string;

    requestPayload:
      Record<string, unknown>;
  },
): Promise<AcquireToolExecutionResult> {

  const {
    data,
    error,
  } = await supabaseAdmin
    .from("tool_executions")
    .insert({
      call_id:
        input.canonicalCallId,

      provider:
        "RETELL",

      provider_tool_call_id:
        null,

      tool_name:
        input.toolName,

      idempotency_key:
        input.idempotencyKey,

      request_hash:
        input.requestHash,

      request_payload:
        input.requestPayload,

      outcome:
        "PENDING",
    })
    .select(
      [
        "tool_execution_id",
        "correlation_id",
        "request_hash",
        "outcome",
        "response_payload",
      ].join(","),
    )
    .single();


  if (
    !error &&
    data
  ) {
    return {
      ok: true,

      record:
        data as ToolExecutionRecord,

      cachedResponse:
        null,

      replay:
        false,

      ownsExecution:
        true,
    };
  }


  if (
    error?.code !== "23505"
  ) {
    return {
      ok: false,
      errorCode:
        "INTERNAL_ERROR",
    };
  }


  const existing =
    await readToolExecution(
      supabaseAdmin,
      input.idempotencyKey,
    );


  if (!existing) {
    return {
      ok: false,
      errorCode:
        "INTERNAL_ERROR",
    };
  }


  if (
    existing.request_hash !==
      input.requestHash
  ) {
    return {
      ok: false,
      errorCode:
        "IDEMPOTENCY_CONFLICT",
    };
  }


  if (
    TERMINAL_OUTCOMES.has(
      existing.outcome,
    )
  ) {

    if (
      !isRecord(
        existing.response_payload,
      )
    ) {
      return {
        ok: false,
        errorCode:
          "INTERNAL_ERROR",
      };
    }


    return {
      ok: true,

      record:
        existing,

      cachedResponse:
        existing.response_payload,

      replay:
        true,

      ownsExecution:
        false,
    };
  }


  const waited =
    await waitForTerminalExecution(
      supabaseAdmin,
      {
        idempotencyKey:
          input.idempotencyKey,

        requestHash:
          input.requestHash,
      },
    );


  if (!waited.ok) {
    return waited;
  }


  return {
    ok: true,

    record:
      waited.record,

    cachedResponse:
      waited.cachedResponse,

    replay:
      true,

    ownsExecution:
      false,
  };
}


export async function completeToolExecution(
  supabaseAdmin: SupabaseClient,

  input: {
    toolExecutionId: string;

    prospectId:
      | string
      | null;

    opportunityId:
      | string
      | null;

    response:
      Record<string, unknown>;

    outcome:
      | "SUCCEEDED"
      | "FAILED"
      | "REJECTED";

    errorCode:
      | string
      | null;
  },
): Promise<boolean> {

  const {
    error,
  } = await supabaseAdmin
    .from("tool_executions")
    .update({
      prospect_id:
        input.prospectId,

      opportunity_id:
        input.opportunityId,

      response_payload:
        input.response,

      outcome:
        input.outcome,

      error_code:
        input.errorCode,

      completed_at:
        new Date()
          .toISOString(),
    })
    .eq(
      "tool_execution_id",
      input.toolExecutionId,
    )
    .eq(
      "outcome",
      "PENDING",
    );


  return !error;
}