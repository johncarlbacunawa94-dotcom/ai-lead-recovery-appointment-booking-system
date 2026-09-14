import {
  createClient,
} from "npm:@supabase/supabase-js@^2";

import {
  renderTwilioSmsTemplate,
  sendTwilioRecoverySms,
} from "../_shared/twilio-sms-transport.ts";

import type {
  TwilioSmsMockScenario,
  TwilioSmsTemplateCode,
  TwilioSmsTransportConfig,
} from "../_shared/twilio-sms-transport.ts";


type BeginRow = {
  disposition: string;
  next_action: string;

  outbound_message_attempt_id:
    | string
    | null;

  outbox_event_id: string;
  outbox_attempt_number: number;

  correlation_id: string;

  call_id:
    | string
    | null;

  prospect_id:
    | string
    | null;

  contact_point_id:
    | string
    | null;

  to_phone:
    | string
    | null;

  template_code:
    | string
    | null;

  provider_message_id:
    | string
    | null;

  provider_status:
    | string
    | null;

  reason_code: string;

  message_id:
    | string
    | null;

  review_outbox_event_id:
    | string
    | null;
};


type FinalizeRow = {
  disposition: string;
  next_action: string;

  attempt_state: string;

  outbound_message_attempt_id:
    string;

  source_outbox_event_id:
    string;

  outbox_attempt_number:
    number;

  provider_message_id:
    | string
    | null;

  conversation_id:
    | string
    | null;

  message_id:
    | string
    | null;

  failure_event_id:
    | string
    | null;

  review_outbox_event_id:
    | string
    | null;

  retry_after_seconds:
    | number
    | null;

  reason_code:
    string;
};


type WorkerRequest = {
  outbox_event_id: string;
  worker_id: string;
};


const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;


const MAX_BODY_CHARACTERS =
  10_000;


function jsonResponse(
  status: number,
  body: Record<string, unknown>,
): Response {

  return new Response(
    JSON.stringify(body),
    {
      status,

      headers: {
        "content-type":
          "application/json; charset=utf-8",

        "cache-control":
          "no-store",

        "x-content-type-options":
          "nosniff",
      },
    },
  );
}


function logEvent(
  event: Record<string, unknown>,
): void {

  console.log(
    JSON.stringify(event),
  );
}


function constantTimeEqual(
  left: string,
  right: string,
): boolean {

  const leftBytes =
    new TextEncoder()
      .encode(left);

  const rightBytes =
    new TextEncoder()
      .encode(right);


  if (
    leftBytes.length !==
    rightBytes.length
  ) {
    return false;
  }


  let difference =
    0;


  for (
    let index = 0;
    index < leftBytes.length;
    index += 1
  ) {
    difference |=
      leftBytes[index] ^
      rightBytes[index];
  }


  return difference === 0;
}


function isRecord(
  value: unknown,
): value is Record<string, unknown> {

  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value)
  );
}


function parseWorkerRequest(
  value: unknown,
):
  | {
      ok: true;
      value: WorkerRequest;
    }
  | {
      ok: false;
    } {

  if (!isRecord(value)) {
    return {
      ok: false,
    };
  }


  const allowedKeys =
    new Set([
      "outbox_event_id",
      "worker_id",
    ]);


  for (
    const key of
    Object.keys(value)
  ) {
    if (!allowedKeys.has(key)) {
      return {
        ok: false,
      };
    }
  }


  if (
    typeof value.outbox_event_id !==
      "string"
    ||
    !UUID_PATTERN.test(
      value.outbox_event_id,
    )
  ) {
    return {
      ok: false,
    };
  }


  if (
    typeof value.worker_id !==
      "string"
  ) {
    return {
      ok: false,
    };
  }


  const workerId =
    value.worker_id.trim();


  if (
    workerId.length === 0 ||
    workerId.length > 200
  ) {
    return {
      ok: false,
    };
  }


  return {
    ok: true,

    value: {
      outbox_event_id:
        value.outbox_event_id,

      worker_id:
        workerId,
    },
  };
}


function firstRpcRow<T>(
  value: unknown,
): T | null {

  if (
    !Array.isArray(value) ||
    value.length !== 1
  ) {
    return null;
  }


  if (!isRecord(value[0])) {
    return null;
  }


  return value[0] as T;
}


function requireEnvironment(
  name: string,
): string {

  const value =
    Deno.env.get(name)
      ?.trim();


  if (!value) {
    throw new Error(
      `Missing required environment variable: ${name}`,
    );
  }


  return value;
}


function getMockScenario():
  TwilioSmsMockScenario {

  const configured =
    (
      Deno.env.get(
        "TWILIO_SMS_MOCK_SCENARIO",
      ) ??
      "SUCCESS"
    )
      .trim()
      .toUpperCase();


  switch (configured) {

    case "SUCCESS":
    case "REJECTED_400":
    case "REJECTED_429":
    case "UNKNOWN_NETWORK":

      return configured;


    default:

      throw new Error(
        "Invalid TWILIO_SMS_MOCK_SCENARIO",
      );
  }
}


function getTransportConfig():
  TwilioSmsTransportConfig {

  const mode =
    (
      Deno.env.get(
        "TWILIO_SMS_TRANSPORT_MODE",
      ) ??
      ""
    )
      .trim()
      .toUpperCase();


  if (mode === "MOCK") {

    return {
      mode:
        "MOCK",

      accountSid:
        "AC11111111111111111111111111111111",

      authToken:
        "phase6c4-local-mock-token",

      fromPhone:
        "+61400000000",

      statusCallbackUrl:
        "https://example.test/twilio/message-status",

      mockScenario:
        getMockScenario(),
    };
  }


  if (mode === "LIVE") {

    return {
      mode:
        "LIVE",

      accountSid:
        requireEnvironment(
          "TWILIO_ACCOUNT_SID",
        ),

      authToken:
        requireEnvironment(
          "TWILIO_AUTH_TOKEN",
        ),

      fromPhone:
        requireEnvironment(
          "TWILIO_SMS_FROM_PHONE",
        ),

      statusCallbackUrl:
        requireEnvironment(
          "TWILIO_SMS_STATUS_CALLBACK_URL",
        ),
    };
  }


  throw new Error(
    "TWILIO_SMS_TRANSPORT_MODE must be explicitly MOCK or LIVE",
  );
}


Deno.serve(
  async (
    request: Request,
  ): Promise<Response> => {

    const requestCorrelationId =
      crypto.randomUUID();


    if (
      request.method !== "POST"
    ) {
      return jsonResponse(
        405,
        {
          error: {
            code:
              "METHOD_NOT_ALLOWED",

            message:
              "Only POST is supported.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const expectedWorkerSecret =
      Deno.env.get(
        "TWILIO_RECOVERY_WORKER_SECRET",
      );


    if (!expectedWorkerSecret) {

      console.error(
        JSON.stringify({
          event:
            "twilio_recovery_sms_configuration_error",

          reason:
            "worker_secret_missing",

          request_correlation_id:
            requestCorrelationId,
        }),
      );


      return jsonResponse(
        503,
        {
          error: {
            code:
              "SERVICE_UNAVAILABLE",

            message:
              "Recovery SMS service is unavailable.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const suppliedWorkerSecret =
      request.headers.get(
        "x-recovery-worker-secret",
      ) ?? "";


    if (
      !constantTimeEqual(
        suppliedWorkerSecret,
        expectedWorkerSecret,
      )
    ) {

      logEvent({
        level:
          "warning",

        event:
          "twilio_recovery_sms_auth_rejected",

        request_correlation_id:
          requestCorrelationId,
      });


      return jsonResponse(
        401,
        {
          error: {
            code:
              "UNAUTHORIZED",

            message:
              "Unauthorized.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const contentType =
      request.headers
        .get(
          "content-type",
        )
        ?.toLowerCase() ??
      "";


    if (
      !contentType.startsWith(
        "application/json",
      )
    ) {
      return jsonResponse(
        415,
        {
          error: {
            code:
              "UNSUPPORTED_MEDIA_TYPE",

            message:
              "Request must use application/json.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    let rawBody: string;


    try {
      rawBody =
        await request.text();
    } catch {

      return jsonResponse(
        400,
        {
          error: {
            code:
              "INVALID_REQUEST",

            message:
              "Request body could not be read.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    if (
      rawBody.length >
      MAX_BODY_CHARACTERS
    ) {
      return jsonResponse(
        413,
        {
          error: {
            code:
              "INVALID_REQUEST",

            message:
              "Request body is too large.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    let decodedBody:
      unknown;


    try {
      decodedBody =
        JSON.parse(
          rawBody,
        );
    } catch {

      return jsonResponse(
        400,
        {
          error: {
            code:
              "INVALID_REQUEST",

            message:
              "Request body is not valid JSON.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const parsedRequest =
      parseWorkerRequest(
        decodedBody,
      );


    if (!parsedRequest.ok) {

      return jsonResponse(
        400,
        {
          error: {
            code:
              "INVALID_REQUEST",

            message:
              "Request does not match the approved worker contract.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const supabaseUrl =
      Deno.env.get(
        "SUPABASE_URL",
      );


    const serviceRoleKey =
      Deno.env.get(
        "SUPABASE_SERVICE_ROLE_KEY",
      );


    if (
      !supabaseUrl ||
      !serviceRoleKey
    ) {

      console.error(
        JSON.stringify({
          event:
            "twilio_recovery_sms_configuration_error",

          reason:
            "supabase_configuration_missing",

          request_correlation_id:
            requestCorrelationId,
        }),
      );


      return jsonResponse(
        503,
        {
          error: {
            code:
              "SERVICE_UNAVAILABLE",

            message:
              "Recovery SMS service is unavailable.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    let transportConfig:
      TwilioSmsTransportConfig;


    try {
      transportConfig =
        getTransportConfig();
    } catch (error) {

      console.error(
        JSON.stringify({
          event:
            "twilio_recovery_sms_configuration_error",

          reason:
            error instanceof Error
              ? error.message
              : "unknown_configuration_error",

          request_correlation_id:
            requestCorrelationId,
        }),
      );


      return jsonResponse(
        503,
        {
          error: {
            code:
              "SERVICE_UNAVAILABLE",

            message:
              "Recovery SMS transport is unavailable.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const supabaseAdmin =
      createClient(
        supabaseUrl,
        serviceRoleKey,
        {
          auth: {
            persistSession:
              false,

            autoRefreshToken:
              false,
          },
        },
      );


    const workerRequest =
      parsedRequest.value;


    const {
      data: beginData,
      error: beginError,
    } =
      await supabaseAdmin.rpc(
        "begin_twilio_recovery_sms_attempt_v1",
        {
          p_outbox_event_id:
            workerRequest.outbox_event_id,

          p_worker_id:
            workerRequest.worker_id,
        },
      );


    if (beginError) {

      console.error(
        JSON.stringify({
          event:
            "twilio_recovery_sms_begin_failed",

          database_code:
            beginError.code ?? null,

          outbox_event_id:
            workerRequest.outbox_event_id,

          request_correlation_id:
            requestCorrelationId,
        }),
      );


      return jsonResponse(
        409,
        {
          error: {
            code:
              "SEND_PREPARATION_FAILED",

            message:
              "Recovery SMS could not enter the provider boundary safely.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const begin =
      firstRpcRow<BeginRow>(
        beginData,
      );


    if (!begin) {

      return jsonResponse(
        500,
        {
          error: {
            code:
              "INTERNAL_ERROR",

            message:
              "Recovery SMS preparation returned no result.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    logEvent({
      level:
        "info",

      event:
        "twilio_recovery_sms_prepared",

      disposition:
        begin.disposition,

      next_action:
        begin.next_action,

      outbox_event_id:
        begin.outbox_event_id,

      outbox_attempt_number:
        begin.outbox_attempt_number,

      request_correlation_id:
        requestCorrelationId,
    });


    // ------------------------------------------------------------------------
    // PostgreSQL decided that no provider request should be issued.
    // n8n remains responsible for COMPLETE_OUTBOX / FAIL_OUTBOX semantics.
    // ------------------------------------------------------------------------

    if (
      begin.next_action !==
      "SEND_SMS"
    ) {

      return jsonResponse(
        200,
        {
          status:
            begin.disposition,

          next_action:
            begin.next_action,

          reason_code:
            begin.reason_code,

          outbox_event_id:
            begin.outbox_event_id,

          outbox_attempt_number:
            begin.outbox_attempt_number,

          outbound_message_attempt_id:
            begin.outbound_message_attempt_id,

          message_id:
            begin.message_id,

          review_outbox_event_id:
            begin.review_outbox_event_id,

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    if (
      begin.disposition !==
        "RESERVED"
      ||
      !begin.outbound_message_attempt_id
      ||
      !begin.to_phone
      ||
      begin.template_code !==
        "MISSED_CALL_RECOVERY_V1"
    ) {

      console.error(
        JSON.stringify({
          event:
            "twilio_recovery_sms_invalid_begin_contract",

          disposition:
            begin.disposition,

          next_action:
            begin.next_action,

          outbox_event_id:
            begin.outbox_event_id,

          request_correlation_id:
            requestCorrelationId,
        }),
      );


      return jsonResponse(
        500,
        {
          error: {
            code:
              "INTERNAL_ERROR",

            message:
              "Recovery SMS preparation returned an invalid send contract.",
          },

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const templateCode =
      begin.template_code as
        TwilioSmsTemplateCode;


    const messageBody =
      renderTwilioSmsTemplate(
        templateCode,
      );


    const transportResult =
      await sendTwilioRecoverySms(
        transportConfig,

        {
          toPhone:
            begin.to_phone,

          templateCode,
        },
      );


    logEvent({
      level:
        "info",

      event:
        "twilio_recovery_sms_transport_completed",

      provider_outcome:
        transportResult.outcome,

      retryable:
        transportResult.retryable,

      outbox_event_id:
        begin.outbox_event_id,

      outbound_message_attempt_id:
        begin.outbound_message_attempt_id,

      request_correlation_id:
        requestCorrelationId,
    });


    let finalizeArguments:
      Record<string, unknown>;


    if (
      transportResult.outcome ===
      "ACCEPTED"
    ) {

      finalizeArguments = {
        p_outbound_message_attempt_id:
          begin.outbound_message_attempt_id,

        p_worker_id:
          workerRequest.worker_id,

        p_outcome:
          "ACCEPTED",

        p_provider_message_id:
          transportResult.providerMessageId,

        p_provider_status:
          transportResult.providerStatus,

        p_retryable:
          false,

        p_error_code:
          null,

        p_sanitized_message:
          null,

        p_message_body:
          messageBody,
      };

    } else if (
      transportResult.outcome ===
      "REJECTED"
    ) {

      finalizeArguments = {
        p_outbound_message_attempt_id:
          begin.outbound_message_attempt_id,

        p_worker_id:
          workerRequest.worker_id,

        p_outcome:
          "REJECTED",

        p_provider_message_id:
          null,

        p_provider_status:
          null,

        p_retryable:
          transportResult.retryable,

        p_error_code:
          transportResult.errorCode,

        p_sanitized_message:
          transportResult.sanitizedMessage,

        p_message_body:
          null,
      };

    } else {

      finalizeArguments = {
        p_outbound_message_attempt_id:
          begin.outbound_message_attempt_id,

        p_worker_id:
          workerRequest.worker_id,

        p_outcome:
          "UNKNOWN",

        p_provider_message_id:
          null,

        p_provider_status:
          null,

        p_retryable:
          false,

        p_error_code:
          transportResult.errorCode,

        p_sanitized_message:
          transportResult.sanitizedMessage,

        p_message_body:
          null,
      };
    }


    const {
      data: finalizeData,
      error: finalizeError,
    } =
      await supabaseAdmin.rpc(
        "finalize_twilio_recovery_sms_attempt_v1",
        finalizeArguments,
      );


    if (finalizeError) {

      console.error(
        JSON.stringify({
          event:
            "twilio_recovery_sms_finalize_failed",

          database_code:
            finalizeError.code ?? null,

          provider_outcome:
            transportResult.outcome,

          outbox_event_id:
            begin.outbox_event_id,

          outbound_message_attempt_id:
            begin.outbound_message_attempt_id,

          request_correlation_id:
            requestCorrelationId,
        }),
      );


      // Important:
      // A provider request has already occurred.
      // We must not tell the caller to simply retry the SMS request.
      return jsonResponse(
        500,
        {
          error: {
            code:
              "PROVIDER_OUTCOME_PERSISTENCE_FAILED",

            message:
              "Provider processing completed but its durable outcome could not be confirmed. Automatic resend is unsafe.",
          },

          outbox_event_id:
            begin.outbox_event_id,

          outbound_message_attempt_id:
            begin.outbound_message_attempt_id,

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    const finalized =
      firstRpcRow<FinalizeRow>(
        finalizeData,
      );


    if (!finalized) {

      return jsonResponse(
        500,
        {
          error: {
            code:
              "PROVIDER_OUTCOME_PERSISTENCE_FAILED",

            message:
              "Provider outcome persistence returned no result. Automatic resend is unsafe.",
          },

          outbox_event_id:
            begin.outbox_event_id,

          outbound_message_attempt_id:
            begin.outbound_message_attempt_id,

          correlation_id:
            requestCorrelationId,
        },
      );
    }


    return jsonResponse(
      200,
      {
        status:
          finalized.disposition,

        next_action:
          finalized.next_action,

        reason_code:
          finalized.reason_code,

        attempt_state:
          finalized.attempt_state,

        outbox_event_id:
          finalized.source_outbox_event_id,

        outbox_attempt_number:
          finalized.outbox_attempt_number,

        outbound_message_attempt_id:
          finalized.outbound_message_attempt_id,

        provider_outcome:
          transportResult.outcome,

        provider_message_id:
          finalized.provider_message_id,

        conversation_id:
          finalized.conversation_id,

        message_id:
          finalized.message_id,

        failure_event_id:
          finalized.failure_event_id,

        review_outbox_event_id:
          finalized.review_outbox_event_id,

        retry_after_seconds:
          finalized.retry_after_seconds,

        correlation_id:
          requestCorrelationId,
      },
    );
  },
);