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


const EVENT_TYPE_CODE =
  "MERIDIAN_DISCOVERY_30";

const CAL_SLOTS_API_VERSION =
  "2024-09-04";

const CAL_REQUEST_TIMEOUT_MS =
  5000;

const AVAILABILITY_CACHE_BUCKET_MS =
  30_000;

const SLOT_TOKEN_TTL_MS =
  10 * 60 * 1000;


type AvailabilityArgs = {
  requested_timezone: string;
  window_start: string;
  window_end: string;
};


type CalSlotRange = {
  start: string;
  end: string;
};


type PersistAvailabilityResult = {
  booking_request_id: string;
  slot_count: number;
};


type OfferedSlot = {
  slotToken: string;
  slotTokenHash: string;

  startAt: string;
  endAt: string;

  startAtUtc: string;
  endAtUtc: string;
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


function base64Url(
  bytes: Uint8Array,
): string {
  let binary = "";

  for (const byte of bytes) {
    binary +=
      String.fromCharCode(byte);
  }

  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}


function createOpaqueSlotToken(): string {
  const bytes =
    new Uint8Array(32);

  crypto.getRandomValues(bytes);

  return [
    "meridian_slot_v1",
    base64Url(bytes),
  ].join(".");
}


function dateKeyInTimezone(
  date: Date,
  timezone: string,
): string {
  const parts =
    new Intl.DateTimeFormat(
      "en-US",
      {
        timeZone: timezone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
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


function providerErrorResponse(
  correlationId: string,
  resolvedTimezone: string | null,
  errorCode: string,
  message: string,
  retryable: boolean,
): Record<string, unknown> {
  return {
    status:
      "PROVIDER_ERROR",

    correlation_id:
      correlationId,

    booking_request_id:
      null,

    resolved_timezone:
      resolvedTimezone,

    slots:
      [],

    allowed_actions: [
      "REQUEST_HANDOFF",
    ],

    error_code:
      errorCode,

    message_for_agent:
      message,

    retryable,
  };
}


function humanRequiredResponse(
  correlationId: string,
  resolvedTimezone: string | null,
  errorCode: string,
  message: string,
): Record<string, unknown> {
  return {
    status:
      "HUMAN_REQUIRED",

    correlation_id:
      correlationId,

    booking_request_id:
      null,

    resolved_timezone:
      resolvedTimezone,

    slots:
      [],

    allowed_actions: [
      "REQUEST_HANDOFF",
    ],

    error_code:
      errorCode,

    message_for_agent:
      message,

    retryable:
      false,
  };
}


async function finalizeExecution(
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
          "availability_tool_execution_finalize_failed",

        tool_execution_id:
          input.toolExecutionId,

        opportunity_id:
          input.opportunityId,
      }),
    );
  }
}


async function validateBookingContext(
  context: ToolRuntimeContext,
  supabaseAdmin: SupabaseClient,
  requestedTimezone: string,
): Promise<
  | {
      ok: true;
    }
  | {
      ok: false;
      response: Record<string, unknown>;
    }
> {
  if (
    !context.prospectId ||
    !context.opportunityId
  ) {
    return {
      ok: false,

      response:
        humanRequiredResponse(
          context.correlationId,
          requestedTimezone,
          "BOOKING_CONTEXT_UNRESOLVED",
          "The booking context is not safely resolved. Do not offer appointment times. Request human follow-up.",
        ),
    };
  }


  const {
    data: opportunity,
    error: opportunityError,
  } = await supabaseAdmin
    .from("opportunities")
    .select(
      [
        "opportunity_id",
        "prospect_id",
        "lifecycle_state",
      ].join(","),
    )
    .eq(
      "opportunity_id",
      context.opportunityId,
    )
    .eq(
      "prospect_id",
      context.prospectId,
    )
    .maybeSingle();


  if (opportunityError) {
    return {
      ok: false,

      response:
        providerErrorResponse(
          context.correlationId,
          requestedTimezone,
          "INTERNAL_ERROR",
          "Appointment availability could not be checked safely. Do not invent appointment times. Request human follow-up.",
          false,
        ),
    };
  }


  if (!opportunity) {
    return {
      ok: false,

      response:
        humanRequiredResponse(
          context.correlationId,
          requestedTimezone,
          "BOOKING_CONTEXT_UNRESOLVED",
          "The opportunity could not be resolved safely for booking. Do not offer appointment times. Request human follow-up.",
        ),
    };
  }


  if (
    opportunity.lifecycle_state ===
      "BOOKED"
  ) {
    return {
      ok: false,

      response:
        humanRequiredResponse(
          context.correlationId,
          requestedTimezone,
          "ACTIVE_APPOINTMENT_EXISTS",
          "This opportunity is already booked. Do not offer or create another appointment. Request human follow-up if a change is needed.",
        ),
    };
  }


  if (
    opportunity.lifecycle_state !==
      "BOOKING_READY"
  ) {
    return {
      ok: false,

      response:
        humanRequiredResponse(
          context.correlationId,
          requestedTimezone,
          "OPPORTUNITY_NOT_BOOKING_READY",
          "This opportunity is not currently approved for appointment booking. Do not offer appointment times. Request human follow-up.",
        ),
    };
  }


  const {
    data: activeAppointments,
    error: appointmentError,
  } = await supabaseAdmin
    .from("appointments")
    .select(
      "appointment_id,status",
    )
    .eq(
      "opportunity_id",
      context.opportunityId,
    )
    .in(
      "status",
      [
        "CREATE_PENDING",
        "CONFIRMED",
        "RESCHEDULE_PENDING",
      ],
    )
    .limit(1);


  if (appointmentError) {
    return {
      ok: false,

      response:
        providerErrorResponse(
          context.correlationId,
          requestedTimezone,
          "INTERNAL_ERROR",
          "Appointment state could not be checked safely. Do not invent appointment times. Request human follow-up.",
          false,
        ),
    };
  }


  if (
    activeAppointments &&
    activeAppointments.length > 0
  ) {
    return {
      ok: false,

      response:
        humanRequiredResponse(
          context.correlationId,
          requestedTimezone,
          "ACTIVE_APPOINTMENT_EXISTS",
          "An appointment already exists or is being created for this opportunity. Do not create a duplicate booking.",
        ),
    };
  }


  return {
    ok: true,
  };
}


function extractProviderSlots(
  payload: unknown,

  windowStartMs: number,
  windowEndMs: number,
): CalSlotRange[] | null {
  if (
    !isRecord(payload) ||
    !isRecord(payload.data)
  ) {
    return null;
  }


  const candidates:
    Array<{
      start: string;
      end: string;
      startMs: number;
      endMs: number;
    }> = [];


  for (
    const value of
    Object.values(payload.data)
  ) {
    if (!Array.isArray(value)) {
      continue;
    }


    for (const item of value) {
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


      const startMs =
        Date.parse(item.start);

      const endMs =
        Date.parse(item.end);


      if (
        Number.isNaN(startMs) ||
        Number.isNaN(endMs) ||
        endMs <= startMs
      ) {
        continue;
      }


      if (
        startMs < windowStartMs ||
        endMs > windowEndMs
      ) {
        continue;
      }


      if (
        startMs <= Date.now()
      ) {
        continue;
      }


      candidates.push({
        start:
          item.start,

        end:
          item.end,

        startMs,
        endMs,
      });
    }
  }


  candidates.sort(
    (left, right) =>
      left.startMs -
      right.startMs,
  );


  const result:
    CalSlotRange[] = [];

  const seen =
    new Set<string>();


  for (const candidate of candidates) {
    const key =
      [
        candidate.startMs,
        candidate.endMs,
      ].join(":");

    if (seen.has(key)) {
      continue;
    }

    seen.add(key);

    result.push({
      start:
        candidate.start,

      end:
        candidate.end,
    });


    if (result.length === 5) {
      break;
    }
  }


  return result;
}


export async function handleCheckAppointmentAvailability(
  context: ToolRuntimeContext,

  args:
    Record<string, unknown>,

  supabaseAdmin:
    SupabaseClient,
): Promise<Record<string, unknown>> {

  const typedArgs =
    args as unknown as
      AvailabilityArgs;


  const requestedTimezone =
    typedArgs
      .requested_timezone
      .trim();

  const windowStart =
    new Date(
      typedArgs.window_start,
    );

  const windowEnd =
    new Date(
      typedArgs.window_end,
    );


  const contextCheck =
    await validateBookingContext(
      context,
      supabaseAdmin,
      requestedTimezone,
    );


  if (!contextCheck.ok) {
    return contextCheck.response;
  }


  const calApiKey =
    Deno.env.get(
      "CAL_API_KEY",
    );

  const providerEventTypeId =
    Deno.env.get(
      "CAL_EVENT_TYPE_ID",
    );


  if (
    !calApiKey ||
    !providerEventTypeId
  ) {
    return providerErrorResponse(
      context.correlationId,
      requestedTimezone,
      "BOOKING_PROVIDER_CONFIGURATION_ERROR",
      "Appointment availability is temporarily unavailable. Do not invent appointment times. Request human follow-up.",
      false,
    );
  }


  const availabilityBucket =
    Math.floor(
      Date.now() /
        AVAILABILITY_CACHE_BUCKET_MS,
    );


  const normalizedRequest = {
    requested_timezone:
      requestedTimezone,

    window_start:
      windowStart.toISOString(),

    window_end:
      windowEnd.toISOString(),

    event_type_code:
      EVENT_TYPE_CODE,

    provider_event_type_id:
      providerEventTypeId,

    availability_cache_bucket:
      availabilityBucket,
  };


  const {
    requestHash,
    idempotencyKey,
  } = await buildToolRequestIdentity(
    context.providerCallId,
    "check_appointment_availability_v1",
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
          "check_appointment_availability_v1",

        requestHash,
        idempotencyKey,

        requestPayload:
          normalizedRequest,
      },
    );


  if (!execution.ok) {
    return providerErrorResponse(
      context.correlationId,
      requestedTimezone,
      execution.errorCode,
      "Appointment availability could not be checked safely. Do not invent appointment times. Request human follow-up.",
      execution.errorCode ===
        "IDEMPOTENCY_PENDING_TIMEOUT",
    );
  }


  if (execution.cachedResponse) {
    return execution.cachedResponse;
  }


  const executionCorrelationId =
    execution.record
      .correlation_id;


  const startDate =
    dateKeyInTimezone(
      windowStart,
      requestedTimezone,
    );

  const endDate =
    dateKeyInTimezone(
      windowEnd,
      requestedTimezone,
    );


  const url =
    new URL(
      "https://api.cal.com/v2/slots",
    );

  url.searchParams.set(
    "eventTypeId",
    providerEventTypeId,
  );

  url.searchParams.set(
    "start",
    startDate,
  );

  url.searchParams.set(
    "end",
    endDate,
  );

  url.searchParams.set(
    "timeZone",
    requestedTimezone,
  );

  url.searchParams.set(
    "format",
    "range",
  );


  const controller =
    new AbortController();

  const timeout =
    setTimeout(
      () =>
        controller.abort(),
      CAL_REQUEST_TIMEOUT_MS,
    );


  let providerResponse:
    Response;


  try {
    providerResponse =
      await fetch(
        url,
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
            controller.signal,
        },
      );
  } catch {
    clearTimeout(timeout);

    const response =
      providerErrorResponse(
        executionCorrelationId,
        requestedTimezone,
        "BOOKING_PROVIDER_UNAVAILABLE",
        "Appointment availability could not be reached. Do not invent appointment times. Request human follow-up.",
        true,
      );


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_UNAVAILABLE",
      },
    );


    return response;
  } finally {
    clearTimeout(timeout);
  }


  if (!providerResponse.ok) {
    const retryable =
      providerResponse.status === 429 ||
      providerResponse.status >= 500;


    const response =
      providerErrorResponse(
        executionCorrelationId,
        requestedTimezone,
        "BOOKING_PROVIDER_ERROR",
        "The booking provider could not return reliable availability. Do not invent appointment times. Request human follow-up.",
        retryable,
      );


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_ERROR",
      },
    );


    return response;
  }


  let providerPayload:
    unknown;


  try {
    providerPayload =
      await providerResponse
        .json();
  } catch {
    const response =
      providerErrorResponse(
        executionCorrelationId,
        requestedTimezone,
        "BOOKING_PROVIDER_INVALID_RESPONSE",
        "The booking provider returned an invalid availability response. Do not invent appointment times. Request human follow-up.",
        true,
      );


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_INVALID_RESPONSE",
      },
    );


    return response;
  }


  const providerSlots =
    extractProviderSlots(
      providerPayload,
      windowStart.getTime(),
      windowEnd.getTime(),
    );


  if (providerSlots === null) {
    const response =
      providerErrorResponse(
        executionCorrelationId,
        requestedTimezone,
        "BOOKING_PROVIDER_INVALID_RESPONSE",
        "The booking provider returned an invalid availability response. Do not invent appointment times. Request human follow-up.",
        true,
      );


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          "FAILED",

        errorCode:
          "BOOKING_PROVIDER_INVALID_RESPONSE",
      },
    );


    return response;
  }


  if (providerSlots.length === 0) {
    const response = {
      status:
        "NO_AVAILABILITY",

      correlation_id:
        executionCorrelationId,

      booking_request_id:
        null,

      resolved_timezone:
        requestedTimezone,

      slots:
        [],

      allowed_actions: [
        "CHECK_AVAILABILITY",
        "REQUEST_HANDOFF",
      ],

      error_code:
        null,

      message_for_agent:
        "No appointment slots are currently available inside the requested window. Ask for another suitable window or offer human follow-up. Do not invent times.",

      retryable:
        false,
    };


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          "SUCCEEDED",

        errorCode:
          null,
      },
    );


    return response;
  }


  const offeredSlots:
    OfferedSlot[] = [];


  for (const slot of providerSlots) {
    const slotToken =
      createOpaqueSlotToken();

    const slotTokenHash =
      await sha256Hex(
        slotToken,
      );

    offeredSlots.push({
      slotToken,
      slotTokenHash,

      startAt:
        slot.start,

      endAt:
        slot.end,

      startAtUtc:
        new Date(
          slot.start,
        ).toISOString(),

      endAtUtc:
        new Date(
          slot.end,
        ).toISOString(),
    });
  }


  const expiresAt =
    new Date(
      Date.now() +
        SLOT_TOKEN_TTL_MS,
    )
      .toISOString();


  const {
    data: persisted,
    error: persistError,
  } = await supabaseAdmin
    .rpc(
      "persist_booking_availability_v1",
      {
        p_canonical_call_id:
          context.canonicalCallId,

        p_prospect_id:
          context.prospectId,

        p_opportunity_id:
          context.opportunityId,

        p_event_type_code:
          EVENT_TYPE_CODE,

        p_provider_event_type_id:
          providerEventTypeId,

        p_requested_timezone:
          requestedTimezone,

        p_window_start_utc:
          windowStart.toISOString(),

        p_window_end_utc:
          windowEnd.toISOString(),

        p_request_fingerprint:
          requestHash,

        p_expires_at:
          expiresAt,

        p_slots:
          offeredSlots.map(
            (slot) => ({
              slot_token_hash:
                slot.slotTokenHash,

              start_at_utc:
                slot.startAtUtc,

              end_at_utc:
                slot.endAtUtc,

              attendee_timezone:
                requestedTimezone,
            }),
          ),
      },
    )
    .single();


  if (
    persistError ||
    !persisted
  ) {
    const errorMessage =
      persistError?.message ??
      "";


    const isStateConflict =
      errorMessage.includes(
        "OPPORTUNITY_NOT_BOOKING_READY",
      ) ||
      errorMessage.includes(
        "ACTIVE_APPOINTMENT_EXISTS",
      );


    const errorCode =
      errorMessage.includes(
        "ACTIVE_APPOINTMENT_EXISTS",
      )
        ? "ACTIVE_APPOINTMENT_EXISTS"
        : errorMessage.includes(
            "OPPORTUNITY_NOT_BOOKING_READY",
          )
        ? "OPPORTUNITY_NOT_BOOKING_READY"
        : "INTERNAL_ERROR";


    const response =
      isStateConflict
        ? humanRequiredResponse(
            executionCorrelationId,
            requestedTimezone,
            errorCode,
            "Booking state changed while availability was being checked. Do not offer these slots or create a booking. Request human follow-up.",
          )
        : providerErrorResponse(
            executionCorrelationId,
            requestedTimezone,
            errorCode,
            "Appointment availability could not be saved safely. Do not offer these slots or invent appointment times. Request human follow-up.",
            false,
          );


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          isStateConflict
            ? "REJECTED"
            : "FAILED",

        errorCode,
      },
    );


    return response;
  }


  const persistResult =
    persisted as
      PersistAvailabilityResult;


  if (
    !persistResult.booking_request_id ||
    persistResult.slot_count !==
      offeredSlots.length
  ) {
    const response =
      providerErrorResponse(
        executionCorrelationId,
        requestedTimezone,
        "INTERNAL_ERROR",
        "Appointment availability could not be saved safely. Do not offer these slots or invent appointment times. Request human follow-up.",
        false,
      );


    await finalizeExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          context.prospectId,

        opportunityId:
          context.opportunityId,

        response,

        outcome:
          "FAILED",

        errorCode:
          "INTERNAL_ERROR",
      },
    );


    return response;
  }


  const response = {
    status:
      "AVAILABLE",

    correlation_id:
      executionCorrelationId,

    booking_request_id:
      persistResult
        .booking_request_id,

    resolved_timezone:
      requestedTimezone,

    slots:
      offeredSlots.map(
        (slot) => ({
          slot_token:
            slot.slotToken,

          start_at:
            slot.startAt,

          end_at:
            slot.endAt,
        }),
      ),

    allowed_actions: [
      "CONFIRM_BOOKING",
    ],

    error_code:
      null,

    message_for_agent:
      "These are provider-confirmed appointment slots in the caller's requested timezone. Present only these returned times. Do not invent, alter, or combine slots. Availability is not a booking until create_appointment_v1 succeeds.",

    retryable:
      false,
  };


  await finalizeExecution(
    supabaseAdmin,
    {
      toolExecutionId:
        execution.record
          .tool_execution_id,

      prospectId:
        context.prospectId,

      opportunityId:
        context.opportunityId,

      response,

      outcome:
        "SUCCEEDED",

      errorCode:
        null,
    },
  );


  return response;
}