import type {
  SupabaseClient,
} from "npm:@supabase/supabase-js@^2";

import type {
  ToolRuntimeContext,
} from "../../_shared/tool-runtime-context.ts";

import {
  acquireToolExecution,
  buildToolRequestIdentity,
  completeToolExecution,
} from "../../_shared/tool-idempotency.ts";

import {
  reconcileAmbiguousCalBooking,
} from "../../_shared/cal-booking-reconciliation.ts";


const CAL_SLOTS_API_VERSION =
  "2024-09-04";

const CAL_BOOKINGS_API_VERSION =
  "2026-02-25";

const CAL_SLOT_TIMEOUT_MS =
  2500;

const CAL_BOOKING_TIMEOUT_MS =
  12000;


type ClaimResult = {
  result_status:
    | "CLAIMED"
    | "ALREADY_BOOKED"
    | "HUMAN_REQUIRED";

  appointment_id:
    | string
    | null;

  provider_booking_uid:
    | string
    | null;

  provider_event_type_id:
    | string
    | null;

  start_at_utc:
    | string
    | null;

  end_at_utc:
    | string
    | null;

  attendee_timezone:
    | string
    | null;

  attendee_name:
    | string
    | null;

  attendee_email:
    | string
    | null;

  error_code:
    | string
    | null;
};


type FinalizeResult = {
  result_status:
    | "CONFIRMED"
    | "ALREADY_BOOKED"
    | "CONFIRMED_REVIEW_REQUIRED"
    | "ERROR";

  booking_request_id:
    | string
    | null;

  opportunity_id:
    | string
    | null;

  provider_booking_uid:
    | string
    | null;

  start_at_utc:
    | string
    | null;

  end_at_utc:
    | string
    | null;

  provider_time_mismatch:
    boolean;

  error_code:
    | string
    | null;
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


function isUuid(
  value: string,
): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
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


function dateKeyInTimezone(
  value: string,
  timezone: string,
): string {
  const date =
    new Date(value);

  const parts =
    new Intl.DateTimeFormat(
      "en-US",
      {
        timeZone:
          timezone,

        year:
          "numeric",

        month:
          "2-digit",

        day:
          "2-digit",
      },
    )
      .formatToParts(date);

  const values:
    Record<string, string> = {};

  for (const part of parts) {
    if (
      part.type === "year" ||
      part.type === "month" ||
      part.type === "day"
    ) {
      values[part.type] =
        part.value;
    }
  }

  return [
    values.year,
    values.month,
    values.day,
  ].join("-");
}


function response(
  input: {
    status:
      | "BOOKED"
      | "ALREADY_BOOKED"
      | "SLOT_UNAVAILABLE"
      | "HUMAN_REQUIRED"
      | "PROVIDER_ERROR";

    correlationId:
      string;

    appointmentId?:
      string | null;

    providerBookingUid?:
      string | null;

    startAt?:
      string | null;

    endAt?:
      string | null;

    allowedActions:
      string[];

    errorCode?:
      string | null;

    message:
      string;

    retryable?:
      boolean;
  },
): Record<string, unknown> {
  return {
    status:
      input.status,

    correlation_id:
      input.correlationId,

    appointment_id:
      input.appointmentId ??
      null,

    provider_booking_uid:
      input.providerBookingUid ??
      null,

    start_at:
      input.startAt ??
      null,

    end_at:
      input.endAt ??
      null,

    allowed_actions:
      input.allowedActions,

    error_code:
      input.errorCode ??
      null,

    message_for_agent:
      input.message,

    retryable:
      input.retryable ??
      false,
  };
}


async function finishToolExecution(
  supabaseAdmin: SupabaseClient,

  input: {
    toolExecutionId:
      string;

    prospectId:
      string | null;

    opportunityId:
      string | null;

    response:
      Record<string, unknown>;

    outcome:
      | "SUCCEEDED"
      | "FAILED"
      | "REJECTED";

    errorCode:
      string | null;
  },
): Promise<void> {
  const completed =
    await completeToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          input.toolExecutionId,

        prospectId:
          input.prospectId,

        opportunityId:
          input.opportunityId,

        response:
          input.response,

        outcome:
          input.outcome,

        errorCode:
          input.errorCode,
      },
    );

  if (!completed) {
    console.error(
      JSON.stringify({
        event:
          "create_appointment_tool_execution_finalize_failed",

        tool_execution_id:
          input.toolExecutionId,

        opportunity_id:
          input.opportunityId,
      }),
    );
  }
}


async function markCreateFailed(
  supabaseAdmin: SupabaseClient,

  appointmentId: string,

  errorCode: string,

  providerStatus:
    string | null,
): Promise<void> {
  const {
    error,
  } = await supabaseAdmin
    .rpc(
      "fail_booking_creation_v1",
      {
        p_appointment_id:
          appointmentId,

        p_error_code:
          errorCode,

        p_provider_status:
          providerStatus,
      },
    );

  if (error) {
    console.error(
      JSON.stringify({
        event:
          "booking_failure_state_persist_failed",

        appointment_id:
          appointmentId,

        error_code:
          errorCode,
      }),
    );
  }
}


function mapClaimFailure(
  claim: ClaimResult,
  correlationId: string,
): Record<string, unknown> {
  const code =
    claim.error_code ??
    "HUMAN_REQUIRED";


  if (
    code ===
      "BOOKING_REQUEST_EXPIRED" ||
    code ===
      "SLOT_TOKEN_EXPIRED" ||
    code ===
      "SLOT_NOT_BOOKABLE"
  ) {
    return response({
      status:
        "SLOT_UNAVAILABLE",

      correlationId,

      appointmentId:
        claim.appointment_id,

      startAt:
        claim.start_at_utc,

      endAt:
        claim.end_at_utc,

      allowedActions: [
        "CHECK_AVAILABILITY",
      ],

      errorCode:
        code ===
          "BOOKING_REQUEST_EXPIRED"
          ? "SLOT_TOKEN_EXPIRED"
          : code ===
              "SLOT_NOT_BOOKABLE"
          ? "SLOT_UNAVAILABLE"
          : code,

      message:
        "That offered appointment time is no longer valid. Check availability again and present only newly returned slots.",
    });
  }


  if (
    code ===
      "INVALID_SLOT_TOKEN"
  ) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        "SLOT_TOKEN_INVALID",

      message:
        "The selected appointment reference could not be validated. Do not construct or modify a slot token. Request human follow-up.",
    });
  }


  if (
    code ===
      "MISSING_BOOKING_NAME" ||
    code ===
      "MISSING_BOOKING_EMAIL"
  ) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        "MISSING_REQUIRED_CONTACT",

      message:
        "Required booking contact information is missing from the canonical contact record. Do not invent attendee details. Request human follow-up.",
    });
  }


  if (
    code ===
      "ACTIVE_APPOINTMENT_EXISTS" ||
    code ===
      "BOOKING_OPERATION_ALREADY_STARTED"
  ) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId,

      appointmentId:
        claim.appointment_id,

      providerBookingUid:
        claim.provider_booking_uid,

      startAt:
        claim.start_at_utc,

      endAt:
        claim.end_at_utc,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        "ALREADY_BOOKED",

      message:
        "A booking already exists or a booking operation has already started for this opportunity. Do not create another appointment.",
    });
  }


  if (
    code ===
      "OPPORTUNITY_NOT_BOOKING_READY"
  ) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        "OPPORTUNITY_STATE_CONFLICT",

      message:
        "The opportunity is no longer in a booking-ready state. Do not create an appointment. Request human follow-up.",
    });
  }


  return response({
    status:
      "HUMAN_REQUIRED",

    correlationId,

    allowedActions: [
      "REQUEST_HANDOFF",
    ],

    errorCode:
      code,

    message:
      "The booking request could not be validated safely. Do not create or claim an appointment. Request human follow-up.",
  });
}


function exactSlotExists(
  payload: unknown,

  expectedStart: string,

  expectedEnd: string,
): boolean {
  if (
    !isRecord(payload) ||
    !isRecord(payload.data)
  ) {
    return false;
  }

  const expectedStartMs =
    Date.parse(
      expectedStart,
    );

  const expectedEndMs =
    Date.parse(
      expectedEnd,
    );


  for (
    const daySlots of
    Object.values(payload.data)
  ) {
    if (!Array.isArray(daySlots)) {
      continue;
    }


    for (const item of daySlots) {
      if (!isRecord(item)) {
        continue;
      }

      if (
        typeof item.start !==
          "string" ||
        typeof item.end !==
          "string"
      ) {
        continue;
      }

      if (
        Date.parse(item.start) ===
          expectedStartMs &&
        Date.parse(item.end) ===
          expectedEndMs
      ) {
        return true;
      }
    }
  }

  return false;
}


export async function handleCreateAppointment(
  context: ToolRuntimeContext,

  args:
    Record<string, unknown>,

  supabaseAdmin:
    SupabaseClient,
): Promise<Record<string, unknown>> {

  if (
    !context.prospectId ||
    !context.opportunityId
  ) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId:
        context.correlationId,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        "OPPORTUNITY_UNAVAILABLE",

      message:
        "The canonical booking context is unavailable. Do not create an appointment. Request human follow-up.",
    });
  }


  const bookingRequestId =
    String(
      args.booking_request_id ??
      "",
    )
      .trim();

  const slotToken =
    String(
      args.slot_token ??
      "",
    )
      .trim();


  if (
    !isUuid(
      bookingRequestId,
    )
  ) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId:
        context.correlationId,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        "BOOKING_REQUEST_NOT_FOUND",

      message:
        "The booking request reference is invalid. Use only the booking_request_id returned by the availability tool.",
    });
  }


  const slotTokenHash =
    await sha256Hex(
      slotToken,
    );


  const normalizedRequest = {
    booking_request_id:
      bookingRequestId,

    slot_token_hash:
      slotTokenHash,
  };


  const {
    requestHash,
    idempotencyKey,
  } = await buildToolRequestIdentity(
    context.providerCallId,
    "create_appointment_v1",
    normalizedRequest,
  );


  const execution =
    await acquireToolExecution(
      supabaseAdmin,
      {
        canonicalCallId:
          context.canonicalCallId,

        providerCallId:
          context.providerCallId,

        toolName:
          "create_appointment_v1",

        requestHash,
        idempotencyKey,

        requestPayload:
          normalizedRequest,
      },
    );


  if (!execution.ok) {
    return response({
      status:
        "HUMAN_REQUIRED",

      correlationId:
        context.correlationId,

      allowedActions: [
        "REQUEST_HANDOFF",
      ],

      errorCode:
        execution.errorCode,

      message:
        "The booking operation could not be safely resolved. Do not retry or create another appointment automatically. Request human follow-up.",
    });
  }


  if (execution.cachedResponse) {
    return execution.cachedResponse;
  }


  const correlationId =
    execution.record
      .correlation_id;


  const {
    data: claimData,
    error: claimError,
  } = await supabaseAdmin
    .rpc(
      "claim_booking_creation_v1",
      {
        p_canonical_call_id:
          context.canonicalCallId,

        p_prospect_id:
          context.prospectId,

        p_opportunity_id:
          context.opportunityId,

        p_booking_request_id:
          bookingRequestId,

        p_slot_token_hash:
          slotTokenHash,
      },
    )
    .single();


  if (
    claimError ||
    !claimData
  ) {
    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "INTERNAL_ERROR",

        message:
          "The booking request could not be claimed safely. Do not create an appointment. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "INTERNAL_ERROR",
      },
    );


    return toolResponse;
  }


  const claim =
    claimData as
      ClaimResult;


  if (
    claim.result_status ===
      "ALREADY_BOOKED"
  ) {
    const toolResponse =
      response({
        status:
          "ALREADY_BOOKED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        providerBookingUid:
          claim.provider_booking_uid,

        startAt:
          claim.start_at_utc,

        endAt:
          claim.end_at_utc,

        allowedActions: [
          "NONE",
        ],

        errorCode:
          "ALREADY_BOOKED",

        message:
          "This opportunity is already booked. Do not create another appointment.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "SUCCEEDED",

        errorCode:
          "ALREADY_BOOKED",
      },
    );


    return toolResponse;
  }


  if (
    claim.result_status !==
      "CLAIMED"
  ) {
    const toolResponse =
      mapClaimFailure(
        claim,
        correlationId,
      );


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "REJECTED",

        errorCode:
          claim.error_code,
      },
    );


    return toolResponse;
  }


  if (
    !claim.appointment_id ||
    !claim.provider_event_type_id ||
    !claim.start_at_utc ||
    !claim.end_at_utc ||
    !claim.attendee_timezone ||
    !claim.attendee_name ||
    !claim.attendee_email
  ) {
    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "INTERNAL_ERROR",

        message:
          "The claimed booking is missing required server-side data. Do not call the booking provider. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "INTERNAL_ERROR",
      },
    );


    return toolResponse;
  }


  const eventTypeId =
    Number(
      claim.provider_event_type_id,
    );


  if (
    !Number.isSafeInteger(
      eventTypeId,
    ) ||
    eventTypeId <= 0
  ) {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "INVALID_PROVIDER_EVENT_TYPE_ID",
      null,
    );


    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "INTERNAL_ERROR",

        message:
          "The booking provider configuration is invalid. Do not create an appointment. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "INTERNAL_ERROR",
      },
    );


    return toolResponse;
  }


  const calApiKey =
    Deno.env.get(
      "CAL_API_KEY",
    );


  if (!calApiKey) {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      null,
    );


    const toolResponse =
      response({
        status:
          "PROVIDER_ERROR",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The booking provider is not configured. Do not claim an appointment was created. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  // --------------------------------------------------------------------------
  // Revalidate the exact selected slot with Cal.com immediately before create.
  // --------------------------------------------------------------------------

  const localDate =
    dateKeyInTimezone(
      claim.start_at_utc,
      claim.attendee_timezone,
    );

  const slotsUrl =
    new URL(
      "https" +
      "://api.cal.com/v2/slots",
    );

  slotsUrl.searchParams.set(
    "eventTypeId",
    String(
      eventTypeId,
    ),
  );

  slotsUrl.searchParams.set(
    "start",
    localDate,
  );

  slotsUrl.searchParams.set(
    "end",
    localDate,
  );

  slotsUrl.searchParams.set(
    "timeZone",
    claim.attendee_timezone,
  );

  slotsUrl.searchParams.set(
    "format",
    "range",
  );


  const slotController =
    new AbortController();

  const slotTimeout =
    setTimeout(
      () =>
        slotController.abort(),
      CAL_SLOT_TIMEOUT_MS,
    );


  let slotResponse:
    Response;


  try {
    slotResponse =
      await fetch(
        slotsUrl,
        {
          method:
            "GET",

          headers: {
            Authorization:
              `Bearer ${calApiKey}`,

            "cal-api-version":
              CAL_SLOTS_API_VERSION,

            Accept:
              "application/json",
          },

          signal:
            slotController.signal,
        },
      );
  } catch {
    clearTimeout(
      slotTimeout,
    );


    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      null,
    );


    const toolResponse =
      response({
        status:
          "PROVIDER_ERROR",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The selected slot could not be revalidated with the booking provider. Do not create or claim an appointment. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  } finally {
    clearTimeout(
      slotTimeout,
    );
  }


  if (!slotResponse.ok) {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      `SLOTS_HTTP_${slotResponse.status}`,
    );


    const toolResponse =
      response({
        status:
          "PROVIDER_ERROR",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The booking provider could not safely revalidate the selected appointment time. Do not claim a booking exists. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  let slotPayload:
    unknown;


  try {
    slotPayload =
      await slotResponse
        .json();
  } catch {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      "INVALID_SLOT_RESPONSE",
    );


    const toolResponse =
      response({
        status:
          "PROVIDER_ERROR",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The booking provider returned an invalid slot response. Do not claim an appointment exists. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  if (
    !exactSlotExists(
      slotPayload,
      claim.start_at_utc,
      claim.end_at_utc,
    )
  ) {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "SLOT_UNAVAILABLE",
      "SLOT_REVALIDATION_FAILED",
    );


    const toolResponse =
      response({
        status:
          "SLOT_UNAVAILABLE",

        correlationId,

        appointmentId:
          claim.appointment_id,

        startAt:
          claim.start_at_utc,

        endAt:
          claim.end_at_utc,

        allowedActions: [
          "CHECK_AVAILABILITY",
        ],

        errorCode:
          "SLOT_UNAVAILABLE",

        message:
          "That appointment time is no longer available. Check availability again and present only newly returned slots.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "SUCCEEDED",

        errorCode:
          "SLOT_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  // --------------------------------------------------------------------------
  // Provider create.
  // The start value is canonical UTC from the persisted provider-confirmed slot.
  // --------------------------------------------------------------------------

  const bookingBody = {
    start:
      new Date(
        claim.start_at_utc,
      )
        .toISOString(),

    attendee: {
      name:
        claim.attendee_name,

      email:
        claim.attendee_email,

      timeZone:
        claim.attendee_timezone,

      language:
        "en",
    },

    eventTypeId:
      eventTypeId,

    metadata: {
      source:
        "RETELL",

      bookingRequestId:
        bookingRequestId,

      localAppointmentId:
        claim.appointment_id,
    },
  };


  const bookingController =
    new AbortController();

  const bookingTimeout =
    setTimeout(
      () =>
        bookingController.abort(),
      CAL_BOOKING_TIMEOUT_MS,
    );


  let providerResponse:
    Response;


  try {
    providerResponse =
      await fetch(
        "https" +
        "://api.cal.com/v2/bookings",
        {
          method:
            "POST",

          headers: {
            Authorization:
              `Bearer ${calApiKey}`,

            "cal-api-version":
              CAL_BOOKINGS_API_VERSION,

            "Content-Type":
              "application/json",

            Accept:
              "application/json",
          },

          body:
            JSON.stringify(
              bookingBody,
            ),

          signal:
            bookingController.signal,
        },
      );
  } catch {
    clearTimeout(
      bookingTimeout,
    );


    // A provider write may have succeeded even though its response was lost.
    // Freeze the local operation before any reconciliation lookup.

    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      "CREATE_OUTCOME_AMBIGUOUS",
    );


    const reconciliation =
      await reconcileAmbiguousCalBooking(
        supabaseAdmin,
        {
          calApiKey,

          appointmentId:
            claim.appointment_id,

          bookingRequestId,

          eventTypeId,

          expectedStart:
            claim.start_at_utc,

          expectedEnd:
            claim.end_at_utc,
        },
      );


    if (
      reconciliation.status ===
        "RECONCILED"
    ) {
      const toolResponse =
        response({
          status:
            "BOOKED",

          correlationId,

          appointmentId:
            claim.appointment_id,

          providerBookingUid:
            reconciliation.providerBookingUid,

          startAt:
            reconciliation.startAt,

          endAt:
            reconciliation.endAt,

          allowedActions: [
            "NONE",
          ],

          errorCode:
            null,

          message:
            "The appointment was created by the booking provider and safely reconciled after a delayed provider response.",
        });


      await finishToolExecution(
        supabaseAdmin,
        {
          toolExecutionId:
            execution.record
              .tool_execution_id,

          prospectId:
            context.prospectId,

          opportunityId:
            context.opportunityId,

          response:
            toolResponse,

          outcome:
            "SUCCEEDED",

          errorCode:
            null,
        },
      );


      return toolResponse;
    }


    if (
      reconciliation.status ===
        "REVIEW_REQUIRED" ||
      reconciliation.status ===
        "RECONCILE_ERROR"
    ) {
      const toolResponse =
        response({
          status:
            "HUMAN_REQUIRED",

          correlationId,

          appointmentId:
            claim.appointment_id,

          providerBookingUid:
            reconciliation.providerBookingUid,

          startAt:
            reconciliation.startAt,

          endAt:
            reconciliation.endAt,

          allowedActions: [
            "REQUEST_HANDOFF",
          ],

          errorCode:
            "BOOKING_PROVIDER_UNAVAILABLE",

          message:
            "Provider booking evidence was found, but it could not be reconciled automatically with sufficient certainty. Do not create another appointment. Request human review.",
        });


      await finishToolExecution(
        supabaseAdmin,
        {
          toolExecutionId:
            execution.record
              .tool_execution_id,

          prospectId:
            context.prospectId,

          opportunityId:
            context.opportunityId,

          response:
            toolResponse,

          outcome:
            "REJECTED",

          errorCode:
            "BOOKING_PROVIDER_UNAVAILABLE",
        },
      );


      return toolResponse;
    }


    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        startAt:
          claim.start_at_utc,

        endAt:
          claim.end_at_utc,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The provider did not return a definitive creation result and no uniquely matching booking could be verified. Do not retry automatically. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  } finally {
    clearTimeout(
      bookingTimeout,
    );
  }


  if (
    providerResponse.status !==
      201
  ) {
    const providerStatus =
      `CREATE_HTTP_${providerResponse.status}`;


    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      providerResponse.status === 409
        ? "SLOT_UNAVAILABLE"
        : "BOOKING_PROVIDER_UNAVAILABLE",
      providerStatus,
    );


    const isSlotConflict =
      providerResponse.status ===
        409;


    const toolResponse =
      response({
        status:
          isSlotConflict
            ? "SLOT_UNAVAILABLE"
            : "PROVIDER_ERROR",

        correlationId,

        appointmentId:
          claim.appointment_id,

        startAt:
          claim.start_at_utc,

        endAt:
          claim.end_at_utc,

        allowedActions:
          isSlotConflict
            ? [
                "CHECK_AVAILABILITY",
              ]
            : [
                "REQUEST_HANDOFF",
              ],

        errorCode:
          isSlotConflict
            ? "SLOT_UNAVAILABLE"
            : "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          isSlotConflict
            ? "The selected appointment time was no longer available when booking was attempted. Check availability again."
            : "The booking provider rejected the appointment creation request. Do not claim a booking exists. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          isSlotConflict
            ? "SUCCEEDED"
            : "FAILED",

        errorCode:
          isSlotConflict
            ? "SLOT_UNAVAILABLE"
            : "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  let providerPayload:
    unknown;


  try {
    providerPayload =
      await providerResponse
        .json();
  } catch {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      "CREATE_RESPONSE_INVALID",
    );


    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The booking provider accepted the request but returned an unreadable result. A booking may exist. Do not retry or claim success. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  if (
    !isRecord(
      providerPayload,
    ) ||
    providerPayload.status !==
      "success" ||
    !isRecord(
      providerPayload.data,
    )
  ) {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      "CREATE_RESPONSE_INVALID",
    );


    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The booking provider returned an unexpected creation result. A booking may exist. Do not retry automatically. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  const providerData =
    providerPayload.data;


  const providerUid =
    typeof providerData.uid ===
      "string"
      ? providerData.uid
      : null;

  const providerStart =
    typeof providerData.start ===
      "string"
      ? providerData.start
      : null;

  const providerEnd =
    typeof providerData.end ===
      "string"
      ? providerData.end
      : null;

  const providerStatus =
    typeof providerData.status ===
      "string"
      ? providerData.status
      : null;

  const providerBookingId =
    (
      typeof providerData.id ===
        "string" ||
      typeof providerData.id ===
        "number"
    )
      ? String(
          providerData.id,
        )
      : null;

  const meetingUrl =
    typeof providerData.meetingUrl ===
      "string"
      ? providerData.meetingUrl
      : null;


  if (
    !providerUid ||
    !providerStart ||
    !providerEnd ||
    Number.isNaN(
      Date.parse(
        providerStart,
      ),
    ) ||
    Number.isNaN(
      Date.parse(
        providerEnd,
      ),
    )
  ) {
    await markCreateFailed(
      supabaseAdmin,
      claim.appointment_id,
      "BOOKING_PROVIDER_UNAVAILABLE",
      "CREATE_RESPONSE_INCOMPLETE",
    );


    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",

        message:
          "The provider returned an incomplete booking confirmation. A booking may exist. Do not retry or claim success. Request human follow-up.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return toolResponse;
  }


  // --------------------------------------------------------------------------
  // Provider truth exists. Persist it atomically.
  // --------------------------------------------------------------------------

  const {
    data: finalizeData,
    error: finalizeError,
  } = await supabaseAdmin
    .rpc(
      "finalize_booking_creation_v1",
      {
        p_appointment_id:
          claim.appointment_id,

        p_provider_booking_uid:
          providerUid,

        p_provider_booking_id:
          providerBookingId,

        p_provider_start_at:
          providerStart,

        p_provider_end_at:
          providerEnd,

        p_provider_status:
          providerStatus,

        p_meeting_url:
          meetingUrl,
      },
    )
    .single();


  if (
    finalizeError ||
    !finalizeData
  ) {
    console.error(
      JSON.stringify({
        event:
          "provider_booking_created_local_finalize_failed",

        appointment_id:
          claim.appointment_id,

        provider_booking_uid:
          providerUid,
      }),
    );


    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          "INTERNAL_ERROR",

        message:
          "The provider created a booking but local state could not be finalized safely. Do not create another appointment. Request human review.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          "INTERNAL_ERROR",
      },
    );


    return toolResponse;
  }


  const finalized =
    finalizeData as
      FinalizeResult;


  if (
    finalized.result_status ===
      "CONFIRMED_REVIEW_REQUIRED"
  ) {
    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          finalized.error_code ??
          "HUMAN_REQUIRED",

        message:
          "The provider booking exists, but the opportunity state changed during booking. Do not create another appointment. Human review is required.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "REJECTED",

        errorCode:
          finalized.error_code,
      },
    );


    return toolResponse;
  }


  if (
    finalized.result_status !==
      "CONFIRMED" &&
    finalized.result_status !==
      "ALREADY_BOOKED"
  ) {
    const toolResponse =
      response({
        status:
          "HUMAN_REQUIRED",

        correlationId,

        appointmentId:
          claim.appointment_id,

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        allowedActions: [
          "REQUEST_HANDOFF",
        ],

        errorCode:
          finalized.error_code ??
          "INTERNAL_ERROR",

        message:
          "A provider booking may exist but the final booking state could not be reconciled safely. Do not create another appointment. Request human review.",
      });


    await finishToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response:
          toolResponse,

        outcome:
          "FAILED",

        errorCode:
          finalized.error_code ??
          "INTERNAL_ERROR",
      },
    );


    return toolResponse;
  }


  const status =
    finalized.result_status ===
      "ALREADY_BOOKED"
      ? "ALREADY_BOOKED"
      : "BOOKED";


  const toolResponse =
    response({
      status,

      correlationId,

      appointmentId:
        claim.appointment_id,

      providerBookingUid:
        finalized.provider_booking_uid ??
        providerUid,

      startAt:
        finalized.start_at_utc ??
        providerStart,

      endAt:
        finalized.end_at_utc ??
        providerEnd,

      allowedActions: [
        "NONE",
      ],

      errorCode:
        status ===
          "ALREADY_BOOKED"
          ? "ALREADY_BOOKED"
          : null,

      message:
        status ===
          "ALREADY_BOOKED"
          ? "This appointment was already created. Do not create another booking."
          : "The appointment was created and confirmed by the booking provider.",
    });


  await finishToolExecution(
    supabaseAdmin,
    {
      toolExecutionId:
        execution.record
          .tool_execution_id,

      prospectId:
        context.prospectId,

      opportunityId:
        context.opportunityId,

      response:
        toolResponse,

      outcome:
        "SUCCEEDED",

      errorCode:
        status ===
          "ALREADY_BOOKED"
          ? "ALREADY_BOOKED"
          : null,
    },
  );


  return toolResponse;
}