import {
  createClient,
} from "npm:@supabase/supabase-js@^2";

import {
  verifyRetellSignature,
} from "../_shared/retell-signature.ts";

import {
  parseRetellWebhookEvent,
} from "../_shared/retell-webhook-event.ts";


type RpcResultRow = {
  disposition: string;
  raw_provider_event_id: string;
  outbox_event_id: string;
  correlation_id: string;
  event_key: string;
};


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
      },
    },
  );
}


async function sha256Hex(
  value: string,
): Promise<string> {
  const digest =
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(value),
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


Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return new Response(
      null,
      {
        status: 405,

        headers: {
          allow: "POST",
        },
      },
    );
  }


  const retellApiKey =
    Deno.env.get(
      "RETELL_API_KEY",
    );


  const supabaseUrl =
    Deno.env.get(
      "SUPABASE_URL",
    );


  const serviceRoleKey =
    Deno.env.get(
      "SUPABASE_SERVICE_ROLE_KEY",
    );


  if (
    !retellApiKey ||
    !supabaseUrl ||
    !serviceRoleKey
  ) {
    console.error(
      JSON.stringify({
        event:
          "retell_webhook_configuration_error",
      }),
    );


    return jsonResponse(
      500,
      {
        error: {
          code:
            "SERVER_CONFIGURATION_ERROR",
          message:
            "Webhook service is not configured.",
        },
      },
    );
  }


  const rawBody =
    await request.text();


  const signature =
    request.headers.get(
      "x-retell-signature",
    );


  const verification =
    await verifyRetellSignature(
      rawBody,
      retellApiKey,
      signature,
    );


  if (!verification.valid) {
    console.warn(
      JSON.stringify({
        event:
          "retell_webhook_signature_rejected",

        reason:
          verification.reason,
      }),
    );


    return jsonResponse(
      401,
      {
        error: {
          code:
            "INVALID_SIGNATURE",

          reason:
            verification.reason,
        },
      },
    );
  }


  const parsed =
    parseRetellWebhookEvent(
      rawBody,
    );


  if (!parsed.ok) {
    console.warn(
      JSON.stringify({
        event:
          "retell_webhook_payload_rejected",

        error_code:
          parsed.errorCode,
      }),
    );


    return jsonResponse(
      400,
      {
        error: {
          code:
            parsed.errorCode,

          message:
            parsed.message,
        },
      },
    );
  }


  const payloadHash =
    await sha256Hex(
      rawBody,
    );


  const supabaseAdmin =
    createClient(
      supabaseUrl,
      serviceRoleKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
        },
      },
    );


  const {
    data,
    error,
  } =
    await supabaseAdmin.rpc(
      "ingest_retell_provider_event_v1",
      {
        p_event_type:
          parsed.value.event,

        p_provider_call_id:
          parsed.value.providerCallId,

        p_payload_hash:
          payloadHash,

        p_payload:
          parsed.value.payload,
      },
    );


  if (error) {
    console.error(
      JSON.stringify({
        event:
          "retell_webhook_ingestion_failed",

        provider_event_type:
          parsed.value.event,

        provider_call_id:
          parsed.value.providerCallId,

        database_code:
          error.code ?? null,
      }),
    );


    return jsonResponse(
      500,
      {
        error: {
          code:
            "INGESTION_FAILED",

          message:
            "Provider event could not be persisted.",
        },
      },
    );
  }


  const row =
    Array.isArray(data)
      ? data[0] as
          | RpcResultRow
          | undefined
      : undefined;


  if (!row) {
    console.error(
      JSON.stringify({
        event:
          "retell_webhook_ingestion_empty_result",

        provider_event_type:
          parsed.value.event,

        provider_call_id:
          parsed.value.providerCallId,
      }),
    );


    return jsonResponse(
      500,
      {
        error: {
          code:
            "INGESTION_FAILED",

          message:
            "Provider event ingestion returned no result.",
        },
      },
    );
  }


  console.log(
    JSON.stringify({
      event:
        "retell_webhook_ingested",

      provider_event_type:
        parsed.value.event,

      provider_call_id:
        parsed.value.providerCallId,

      disposition:
        row.disposition,

      correlation_id:
        row.correlation_id,
    }),
  );


  // Retell only needs a successful 2xx acknowledgement.
  // Post-call processing occurs asynchronously from the outbox.
  return new Response(
    null,
    {
      status: 204,
    },
  );
});