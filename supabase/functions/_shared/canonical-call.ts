import type {
  SupabaseClient,
} from "npm:@supabase/supabase-js@^2";

import type {
  RetellCallContext,
  RetellCallStatus,
} from "./retell-envelope.ts";


export type CanonicalCallRecord = {
  call_id: string;
  correlation_id: string;

  provider: "RETELL";

  provider_call_id: string;

  call_type:
    | "WEB"
    | "PHONE";

  direction:
    | "INBOUND"
    | "OUTBOUND";

  status:
    | "REGISTERED"
    | "ACTIVE"
    | "ENDED"
    | "ANALYSIS_PENDING"
    | "ANALYZED"
    | "POST_PROCESSED"
    | "FAILED";

  prospect_id:
    | string
    | null;

  opportunity_id:
    | string
    | null;

  started_at:
    | string
    | null;
};


export type ResolveCanonicalCallResult =
  | {
      ok: true;

      disposition:
        | "CREATED"
        | "EXISTING"
        | "RACE_RECOVERED";

      call: CanonicalCallRecord;
    }
  | {
      ok: false;

      errorCode:
        | "CALL_CONTEXT_UNAVAILABLE"
        | "CALL_STATE_CONFLICT"
        | "INTERNAL_ERROR";

      message: string;
    };


const CALL_SELECT = [
  "call_id",
  "correlation_id",
  "provider",
  "provider_call_id",
  "call_type",
  "direction",
  "status",
  "prospect_id",
  "opportunity_id",
  "started_at",
].join(",");


function mapRetellStatus(
  status:
    | RetellCallStatus
    | undefined,
): CanonicalCallRecord["status"] {
  switch (status) {
    case "registered":
      return "REGISTERED";

    case "ongoing":
      return "ACTIVE";

    case "ended":
      return "ENDED";

    case "not_connected":
    case "error":
      return "FAILED";

    default:
      // A custom tool normally executes while a call
      // is active. Missing provider status therefore
      // defaults only to ACTIVE, never to a later state.
      return "ACTIVE";
  }
}


function expectedCallType(
  call: RetellCallContext,
): CanonicalCallRecord["call_type"] {
  return (
    call.call_type ===
      "web_call"
  )
    ? "WEB"
    : "PHONE";
}


function resolveCreationDirection(
  call: RetellCallContext,
):
  | "INBOUND"
  | "OUTBOUND"
  | null {

  // Phase 2B policy:
  // new browser/web calls are inbound lead-entry calls.
  if (
    call.call_type ===
      "web_call"
  ) {
    return "INBOUND";
  }


  // Phone calls are not guessed.
  // Later phone/Twilio work should normally
  // pre-register the canonical call.
  if (
    call.direction ===
      "inbound"
  ) {
    return "INBOUND";
  }


  if (
    call.direction ===
      "outbound"
  ) {
    return "OUTBOUND";
  }


  return null;
}


function providerStartedAt(
  call: RetellCallContext,
): string | null {
  if (
    call.start_timestamp ===
      undefined
  ) {
    return null;
  }

  const date =
    new Date(
      call.start_timestamp,
    );

  if (
    Number.isNaN(
      date.getTime(),
    )
  ) {
    return null;
  }

  return date.toISOString();
}


function callContextConflict(
  existing: CanonicalCallRecord,
  incoming: RetellCallContext,
): string | null {
  const expectedType =
    expectedCallType(
      incoming,
    );

  if (
    existing.call_type !==
      expectedType
  ) {
    return (
      "provider call type conflicts " +
      "with canonical call"
    );
  }


  if (
    incoming.call_type ===
      "web_call" &&
    existing.direction !==
      "INBOUND"
  ) {
    return (
      "web call direction conflicts " +
      "with canonical call"
    );
  }


  if (
    incoming.call_type ===
      "phone_call" &&
    incoming.direction
  ) {
    const incomingDirection =
      incoming.direction ===
        "inbound"
        ? "INBOUND"
        : "OUTBOUND";

    if (
      existing.direction !==
        incomingDirection
    ) {
      return (
        "phone call direction conflicts " +
        "with canonical call"
      );
    }
  }


  return null;
}


async function findCanonicalCall(
  supabaseAdmin: SupabaseClient,
  providerCallId: string,
): Promise<
  | {
      ok: true;
      call:
        | CanonicalCallRecord
        | null;
    }
  | {
      ok: false;
      message: string;
    }
> {
  const {
    data,
    error,
  } = await supabaseAdmin
    .from("calls")
    .select(CALL_SELECT)
    .eq(
      "provider",
      "RETELL",
    )
    .eq(
      "provider_call_id",
      providerCallId,
    )
    .maybeSingle();


  if (error) {
    return {
      ok: false,
      message:
        "canonical call lookup failed",
    };
  }


  return {
    ok: true,

    call:
      data as
        | CanonicalCallRecord
        | null,
  };
}


export async function resolveCanonicalRetellCall(
  supabaseAdmin: SupabaseClient,
  incoming: RetellCallContext,
): Promise<ResolveCanonicalCallResult> {

  // ------------------------------------------------------------
  // 1. Existing canonical row wins.
  // ------------------------------------------------------------

  const initialLookup =
    await findCanonicalCall(
      supabaseAdmin,
      incoming.call_id,
    );


  if (!initialLookup.ok) {
    return {
      ok: false,
      errorCode:
        "INTERNAL_ERROR",
      message:
        initialLookup.message,
    };
  }


  if (initialLookup.call) {
    const conflict =
      callContextConflict(
        initialLookup.call,
        incoming,
      );


    if (conflict) {
      return {
        ok: false,
        errorCode:
          "CALL_STATE_CONFLICT",
        message:
          conflict,
      };
    }


    return {
      ok: true,
      disposition:
        "EXISTING",
      call:
        initialLookup.call,
    };
  }


  // ------------------------------------------------------------
  // 2. New call requires deterministic direction.
  // ------------------------------------------------------------

  const direction =
    resolveCreationDirection(
      incoming,
    );


  if (!direction) {
    return {
      ok: false,
      errorCode:
        "CALL_CONTEXT_UNAVAILABLE",
      message:
        "new phone call requires authoritative direction context",
    };
  }


  const insertPayload = {
    provider:
      "RETELL",

    provider_call_id:
      incoming.call_id,

    call_type:
      expectedCallType(
        incoming,
      ),

    direction,

    status:
      mapRetellStatus(
        incoming.call_status,
      ),

    started_at:
      providerStartedAt(
        incoming,
      ),
  };


  const {
    data,
    error,
  } = await supabaseAdmin
    .from("calls")
    .insert(
      insertPayload,
    )
    .select(
      CALL_SELECT,
    )
    .single();


  if (!error && data) {
    return {
      ok: true,
      disposition:
        "CREATED",

      call:
        data as
          CanonicalCallRecord,
    };
  }


  // ------------------------------------------------------------
  // 3. Unique race:
  //
  // Another request may have created the same
  // (RETELL, provider_call_id) after our first lookup.
  // Re-read instead of treating the race as failure.
  // ------------------------------------------------------------

  if (
    error?.code ===
      "23505"
  ) {
    const raceLookup =
      await findCanonicalCall(
        supabaseAdmin,
        incoming.call_id,
      );


    if (
      !raceLookup.ok
    ) {
      return {
        ok: false,
        errorCode:
          "INTERNAL_ERROR",
        message:
          raceLookup.message,
      };
    }


    if (raceLookup.call) {
      const conflict =
        callContextConflict(
          raceLookup.call,
          incoming,
        );


      if (conflict) {
        return {
          ok: false,
          errorCode:
            "CALL_STATE_CONFLICT",
          message:
            conflict,
        };
      }


      return {
        ok: true,
        disposition:
          "RACE_RECOVERED",

        call:
          raceLookup.call,
      };
    }
  }


  return {
    ok: false,
    errorCode:
      "INTERNAL_ERROR",
    message:
      "canonical call registration failed",
  };
}