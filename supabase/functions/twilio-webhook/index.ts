import {
  createClient,
} from "npm:@supabase/supabase-js@^2";

import {
  verifyTwilioFormSignature,
} from "../_shared/twilio-signature.ts";

import {
  parseTwilioWebhookEvent,
} from "../_shared/twilio-webhook-event.ts";


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

        "cache-control":
          "no-store",

        "x-content-type-options":
          "nosniff",
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
      new TextEncoder().encode(
        value,
      ),
    );


  return Array.from(
    new Uint8Array(
      digest,
    ),
  )
    .map(
      (byte) =>
        byte
          .toString(16)
          .padStart(2, "0"),
    )
    .join("");
}


Deno.serve(
  async (
    request: Request,
  ) => {
    if (
      request.method !==
        "POST"
    ) {
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


    const contentType =
      request.headers
        .get(
          "content-type",
        )
        ?.toLowerCase() ??
      "";


    if (
      !contentType.startsWith(
        "application/x-www-form-urlencoded",
      )
    ) {
      return jsonResponse(
        415,
        {
          error: {
            code:
              "UNSUPPORTED_MEDIA_TYPE",

            message:
              "Twilio webhook must use application/x-www-form-urlencoded.",
          },
        },
      );
    }


    const twilioAuthToken =
      Deno.env.get(
        "TWILIO_AUTH_TOKEN",
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
      !twilioAuthToken ||
      !supabaseUrl ||
      !serviceRoleKey
    ) {
      console.error(
        JSON.stringify({
          event:
            "twilio_webhook_configuration_error",
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


    const parsed =
      parseTwilioWebhookEvent(
        rawBody,
      );


    if (!parsed.ok) {
      console.warn(
        JSON.stringify({
          event:
            "twilio_webhook_payload_rejected",

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


    const configuredWebhookUrl =
      Deno.env.get(
        "TWILIO_WEBHOOK_PUBLIC_URL",
      );


    // Twilio signs the exact webhook URL configured on its side.
    // For normal direct requests request.url is sufficient.
    // TWILIO_WEBHOOK_PUBLIC_URL allows an explicit canonical public URL
    // when operating behind a proxy.
    const verificationUrl =
      configuredWebhookUrl ??
      request.url;


    const signature =
      request.headers.get(
        "x-twilio-signature",
      );


    const verification =
      verifyTwilioFormSignature(
        twilioAuthToken,
        signature,
        verificationUrl,
        parsed.value.params,
      );


    if (!verification.valid) {
      console.warn(
        JSON.stringify({
          event:
            "twilio_webhook_signature_rejected",

          reason:
            verification.reason,

          provider_event_type:
            parsed.value.eventType,
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
            persistSession:
              false,

            autoRefreshToken:
              false,
          },
        },
      );


    const {
      data,
      error,
    } =
      await supabaseAdmin.rpc(
        "ingest_twilio_provider_event_v1",
        {
          p_event_type:
            parsed.value.eventType,

          p_payload_hash:
            payloadHash,

          p_payload:
            parsed.value.params,
        },
      );


    if (error) {
      console.error(
        JSON.stringify({
          event:
            "twilio_webhook_ingestion_failed",

          provider_event_type:
            parsed.value.eventType,

          provider_resource_id:
            parsed.value.providerResourceId,

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
          "twilio_webhook_ingested",

        provider_event_type:
          parsed.value.eventType,

        provider_resource_id:
          parsed.value.providerResourceId,

        disposition:
          row.disposition,

        correlation_id:
          row.correlation_id,
      }),
    );


    // Incoming Messaging webhooks can accept an empty TwiML response.
    // Recovery processing remains asynchronous.
    if (
      parsed.value.eventType ===
        "incoming_message"
    ) {
      return new Response(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response></Response>",
        {
          status: 200,

          headers: {
            "content-type":
              "application/xml; charset=utf-8",
          },
        },
      );
    }


    // Status callbacks only require successful acknowledgement.
    return new Response(
      null,
      {
        status: 204,
      },
    );
  },
);