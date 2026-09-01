import "@supabase/functions-js/edge-runtime.d.ts";

import {
  withSupabase,
} from "@supabase/server";

import {
  errorResponse,
  jsonResponse,
} from "../_shared/http.ts";

import {
  parseRetellToolEnvelope,
} from "../_shared/retell-envelope.ts";

import {
  verifyRetellSignature,
} from "../_shared/retell-signature.ts";

import {
  validateRetellToolArgs,
} from "../_shared/retell-tool-args.ts";

import type {
  ToolRuntimeContext,
} from "../_shared/tool-runtime-context.ts";

import {
  handleCaptureProspectContext,
} from "./handlers/capture-prospect-context.ts";

import {
  handleCheckAppointmentAvailability,
} from "./handlers/check-appointment-availability.ts";

import {
  handleCreateAppointment,
} from "./handlers/create-appointment.ts";

import {
  handleHumanHandoff,
} from "./handlers/request-human-handoff.ts";


const MAX_REQUEST_BODY_CHARACTERS =
  2_000_000;


function logEvent(
  event: Record<string, unknown>,
): void {
  console.log(
    JSON.stringify(event),
  );
}


export default {
  fetch: withSupabase(
    {
      auth: "none",
    },

    async (
      req,
      _ctx,
    ) => {
      const correlationId =
        crypto.randomUUID();

      if (req.method !== "POST") {
        return errorResponse(
          405,
          "INVALID_REQUEST",
          "Only POST is supported.",
          correlationId,
        );
      }


      // ------------------------------------------------------------
      // Read the exact raw body once.
      // Signature verification happens before JSON parsing.
      // ------------------------------------------------------------

      let rawBody: string;

      try {
        rawBody = await req.text();
      } catch {
        return errorResponse(
          400,
          "INVALID_REQUEST",
          "Request body could not be read.",
          correlationId,
        );
      }


      if (
        rawBody.length >
          MAX_REQUEST_BODY_CHARACTERS
      ) {
        return errorResponse(
          413,
          "INVALID_REQUEST",
          "Request body is too large.",
          correlationId,
        );
      }


      const retellApiKey =
        Deno.env.get(
          "RETELL_API_KEY",
        );

      if (!retellApiKey) {
        logEvent({
          level: "error",
          event:
            "retell_api_key_missing",
          correlation_id:
            correlationId,
        });

        return errorResponse(
          503,
          "INTERNAL_ERROR",
          "Voice tool service is unavailable.",
          correlationId,
        );
      }


      const signature =
        req.headers.get(
          "X-Retell-Signature",
        );

      const verification =
        await verifyRetellSignature(
          rawBody,
          retellApiKey,
          signature,
        );


      if (!verification.valid) {
        logEvent({
          level: "warning",
          event:
            "retell_signature_rejected",
          reason:
            verification.reason,
          correlation_id:
            correlationId,
        });

        return errorResponse(
          401,
          "INVALID_SIGNATURE",
          "Unauthorized.",
          correlationId,
        );
      }


      // ------------------------------------------------------------
      // Parse signed provider envelope.
      // ------------------------------------------------------------

      const parsed =
        parseRetellToolEnvelope(
          rawBody,
        );


      if (!parsed.ok) {
        logEvent({
          level: "warning",
          event:
            "retell_envelope_rejected",
          error_code:
            parsed.errorCode,
          correlation_id:
            correlationId,
        });

        return errorResponse(
          parsed.errorCode ===
              "UNSUPPORTED_TOOL"
            ? 404
            : 400,
          parsed.errorCode,
          parsed.message,
          correlationId,
        );
      }


      const envelope =
        parsed.value;


      // ------------------------------------------------------------
      // Contract enforcement.
      //
      // Agent arguments must conform exactly to the approved tool
      // contract before any domain handler is allowed to execute.
      // ------------------------------------------------------------

      const argumentValidation =
        validateRetellToolArgs(
          envelope.name,
          envelope.args,
        );


      if (!argumentValidation.ok) {
        logEvent({
          level: "warning",
          event:
            "retell_tool_arguments_rejected",
          tool_name:
            envelope.name,
          issues:
            argumentValidation.issues,
          correlation_id:
            correlationId,
        });

        return errorResponse(
          400,
          "INVALID_REQUEST",
          "Function arguments do not match the approved contract.",
          correlationId,
        );
      }


      const runtimeContext:
        ToolRuntimeContext = {
          correlationId,

          provider:
            "RETELL",

          providerCallId:
            envelope.call.call_id,

          providerCallType:
            envelope.call.call_type,

          agentId:
            envelope.call.agent_id ??
            null,

          agentVersion:
            envelope.call.agent_version ??
            null,

          direction:
            envelope.call.direction ??
            null,
        };


      logEvent({
        level: "info",
        event:
          "retell_tool_request_verified",
        correlation_id:
          correlationId,
        tool_name:
          envelope.name,
        provider_call_id:
          envelope.call.call_id,
        provider_call_type:
          envelope.call.call_type,
      });


      let result:
        Record<string, unknown>;


      switch (envelope.name) {

        case
          "capture_prospect_context_v1":

          result =
            await handleCaptureProspectContext(
              runtimeContext,
              envelope.args,
            );

          break;


        case
          "check_appointment_availability_v1":

          result =
            await handleCheckAppointmentAvailability(
              runtimeContext,
              envelope.args,
            );

          break;


        case
          "create_appointment_v1":

          result =
            await handleCreateAppointment(
              runtimeContext,
              envelope.args,
            );

          break;


        case
          "request_human_handoff_v1":

          result =
            await handleHumanHandoff(
              runtimeContext,
              envelope.args,
            );

          break;


        default:

          return errorResponse(
            404,
            "UNSUPPORTED_TOOL",
            "Function name is not supported.",
            correlationId,
          );
      }


      logEvent({
        level: "info",
        event:
          "retell_tool_request_completed",
        correlation_id:
          correlationId,
        tool_name:
          envelope.name,
        status:
          result.status ??
          "UNKNOWN",
      });


      return jsonResponse(
        result,
        200,
      );
    },
  ),
};