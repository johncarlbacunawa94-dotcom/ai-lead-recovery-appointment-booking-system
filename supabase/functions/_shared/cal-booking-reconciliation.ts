import type {
  SupabaseClient,
} from "npm:@supabase/supabase-js@^2";


const CAL_BOOKINGS_LIST_API_VERSION =
  "2026-05-01";

const LOOKUP_TIMEOUT_MS =
  3000;

const LOOKUP_DELAYS_MS = [
  0,
  1000,
  2000,
] as const;


export type AmbiguousBookingReconciliation = {
  status:
    | "RECONCILED"
    | "REVIEW_REQUIRED"
    | "NOT_FOUND"
    | "LOOKUP_ERROR"
    | "RECONCILE_ERROR";

  providerBookingUid:
    string | null;

  startAt:
    string | null;

  endAt:
    string | null;

  errorCode:
    string | null;
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


export async function reconcileAmbiguousCalBooking(
  supabaseAdmin: SupabaseClient,

  input: {
    calApiKey: string;
    appointmentId: string;
    bookingRequestId: string;
    eventTypeId: number;
    expectedStart: string;
    expectedEnd: string;
  },
): Promise<AmbiguousBookingReconciliation> {

  const expectedStartMs =
    Date.parse(input.expectedStart);

  const expectedEndMs =
    Date.parse(input.expectedEnd);


  if (
    Number.isNaN(expectedStartMs) ||
    Number.isNaN(expectedEndMs)
  ) {
    return {
      status: "RECONCILE_ERROR",
      providerBookingUid: null,
      startAt: null,
      endAt: null,
      errorCode: "INVALID_EXPECTED_BOOKING_TIME",
    };
  }


  let successfulLookup =
    false;


  for (const delayMs of LOOKUP_DELAYS_MS) {
    if (delayMs > 0) {
      await sleep(delayMs);
    }


    const url =
      new URL(
        "https://api.cal.com/v2/bookings",
      );


    url.searchParams.set(
      "eventTypeId",
      String(input.eventTypeId),
    );

    url.searchParams.set(
      "afterStart",
      new Date(
        expectedStartMs - 60_000,
      ).toISOString(),
    );

    url.searchParams.set(
      "beforeEnd",
      new Date(
        expectedEndMs + 60_000,
      ).toISOString(),
    );

    url.searchParams.set(
      "limit",
      "100",
    );


    const controller =
      new AbortController();

    const timeout =
      setTimeout(
        () => controller.abort(),
        LOOKUP_TIMEOUT_MS,
      );


    let providerResponse:
      Response;


    try {
      providerResponse =
        await fetch(
          url,
          {
            method: "GET",

            headers: {
              Authorization:
                `Bearer ${input.calApiKey}`,

              "cal-api-version":
                CAL_BOOKINGS_LIST_API_VERSION,

              Accept:
                "application/json",
            },

            signal:
              controller.signal,
          },
        );
    } catch {
      clearTimeout(timeout);
      continue;
    } finally {
      clearTimeout(timeout);
    }


    if (!providerResponse.ok) {
      continue;
    }


    let payload:
      unknown;


    try {
      payload =
        await providerResponse.json();
    } catch {
      continue;
    }


    successfulLookup =
      true;


    if (
      !isRecord(payload) ||
      !Array.isArray(payload.data)
    ) {
      continue;
    }


    const matches =
      payload.data.filter(
        (item: unknown) => {

          if (!isRecord(item)) {
            return false;
          }


          if (
            Number(item.eventTypeId) !==
              input.eventTypeId
          ) {
            return false;
          }


          if (
            typeof item.start !== "string" ||
            typeof item.end !== "string" ||
            typeof item.uid !== "string"
          ) {
            return false;
          }


          if (
            Date.parse(item.start) !==
              expectedStartMs ||
            Date.parse(item.end) !==
              expectedEndMs
          ) {
            return false;
          }


          if (!isRecord(item.metadata)) {
            return false;
          }


          return (
            item.metadata.bookingRequestId ===
              input.bookingRequestId &&
            item.metadata.localAppointmentId ===
              input.appointmentId
          );
        },
      );


    if (matches.length === 0) {
      continue;
    }


    if (matches.length > 1) {
      return {
        status:
          "REVIEW_REQUIRED",

        providerBookingUid:
          null,

        startAt:
          input.expectedStart,

        endAt:
          input.expectedEnd,

        errorCode:
          "MULTIPLE_PROVIDER_BOOKINGS_FOUND",
      };
    }


    const booking =
      matches[0];


    if (!isRecord(booking)) {
      continue;
    }


    const providerUid =
      typeof booking.uid === "string"
        ? booking.uid
        : null;

    const providerStart =
      typeof booking.start === "string"
        ? booking.start
        : null;

    const providerEnd =
      typeof booking.end === "string"
        ? booking.end
        : null;


    if (
      !providerUid ||
      !providerStart ||
      !providerEnd
    ) {
      return {
        status:
          "RECONCILE_ERROR",

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        errorCode:
          "PROVIDER_BOOKING_INCOMPLETE",
      };
    }


    const providerBookingId =
      (
        typeof booking.id === "string" ||
        typeof booking.id === "number"
      )
        ? String(booking.id)
        : null;


    const providerStatus =
      typeof booking.status === "string"
        ? booking.status
        : null;


    const meetingUrl =
      typeof booking.meetingUrl === "string"
        ? booking.meetingUrl
        : null;


    const {
      data,
      error,
    } = await supabaseAdmin
      .rpc(
        "reconcile_ambiguous_booking_creation_v1",
        {
          p_appointment_id:
            input.appointmentId,

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
      error ||
      !data ||
      !isRecord(data)
    ) {
      return {
        status:
          "RECONCILE_ERROR",

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        errorCode:
          "LOCAL_RECONCILIATION_FAILED",
      };
    }


    const resultStatus =
      typeof data.result_status === "string"
        ? data.result_status
        : "";


    if (
      resultStatus === "RECONCILED" ||
      resultStatus === "ALREADY_RECONCILED"
    ) {
      return {
        status:
          "RECONCILED",

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        errorCode:
          null,
      };
    }


    if (
      resultStatus ===
        "RECONCILED_REVIEW_REQUIRED"
    ) {
      return {
        status:
          "REVIEW_REQUIRED",

        providerBookingUid:
          providerUid,

        startAt:
          providerStart,

        endAt:
          providerEnd,

        errorCode:
          typeof data.error_code === "string"
            ? data.error_code
            : "RECONCILIATION_REVIEW_REQUIRED",
      };
    }


    return {
      status:
        "RECONCILE_ERROR",

      providerBookingUid:
        providerUid,

      startAt:
        providerStart,

      endAt:
        providerEnd,

      errorCode:
        typeof data.error_code === "string"
          ? data.error_code
          : "LOCAL_RECONCILIATION_FAILED",
    };
  }


  if (successfulLookup) {
    return {
      status:
        "NOT_FOUND",

      providerBookingUid:
        null,

      startAt:
        input.expectedStart,

      endAt:
        input.expectedEnd,

      errorCode:
        "PROVIDER_BOOKING_NOT_FOUND",
    };
  }


  return {
    status:
      "LOOKUP_ERROR",

    providerBookingUid:
      null,

    startAt:
      input.expectedStart,

    endAt:
      input.expectedEnd,

    errorCode:
      "PROVIDER_RECONCILIATION_LOOKUP_FAILED",
  };
}