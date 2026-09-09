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

import {
  resolveCanonicalRetellCall,
} from "../_shared/canonical-call.ts";

import type {
  ToolRuntimeContext,
} from "../_shared/tool-runtime-context.ts";

import {
  handleCaptureProspectContext,
} from "./handlers/capture-prospect-context.ts";

import {
  handleCorrectPrimaryEmail,
} from "./handlers/correct-primary-email.ts";

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
      ctx,
    ) => {
      const requestCorrelationId =
        crypto.randomUUID();


      if (req.method !== "POST") {
        return errorResponse(
          405,
          "INVALID_REQUEST",
          "Only POST is supported.",
          requestCorrelationId,
        );
      }


      let rawBody: string;

      try {
        rawBody =
          await req.text();
      } catch {
        return errorResponse(
          400,
          "INVALID_REQUEST",
          "Request body could not be read.",
          requestCorrelationId,
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
          requestCorrelationId,
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
          request_correlation_id:
            requestCorrelationId,
        });

        return errorResponse(
          503,
          "INTERNAL_ERROR",
          "Voice tool service is unavailable.",
          requestCorrelationId,
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
          request_correlation_id:
            requestCorrelationId,
        });

        return errorResponse(
          401,
          "INVALID_SIGNATURE",
          "Unauthorized.",
          requestCorrelationId,
        );
      }


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
          request_correlation_id:
            requestCorrelationId,
        });

        return errorResponse(
          parsed.errorCode ===
              "UNSUPPORTED_TOOL"
            ? 404
            : 400,

          parsed.errorCode,
          parsed.message,
          requestCorrelationId,
        );
      }


      const envelope =
        parsed.value;


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
          request_correlation_id:
            requestCorrelationId,
        });

        return errorResponse(
          400,
          "INVALID_REQUEST",
          "Function arguments do not match the approved contract.",
          requestCorrelationId,
        );
      }


      // ------------------------------------------------------------
      // Canonical call identity boundary.
      //
      // Signed provider call_id is resolved into a server-owned
      // public.calls.call_id before any business handler executes.
      // ------------------------------------------------------------

      const callResolution =
        await resolveCanonicalRetellCall(
          ctx.supabaseAdmin,
          envelope.call,
        );


      if (!callResolution.ok) {
        logEvent({
          level: "error",
          event:
            "canonical_call_resolution_failed",
          error_code:
            callResolution.errorCode,
          provider_call_id:
            envelope.call.call_id,
          request_correlation_id:
            requestCorrelationId,
        });


        const status =
          callResolution.errorCode ===
              "INTERNAL_ERROR"
            ? 500
            : 409;


        return errorResponse(
          status,
          callResolution.errorCode,

          status === 500
            ? "Voice tool service is unavailable."
            : "Call context could not be resolved safely.",

          requestCorrelationId,
        );
      }


      const canonicalCall =
        callResolution.call;


      const runtimeContext:
        ToolRuntimeContext = {

          correlationId:
            requestCorrelationId,

          provider:
            "RETELL",

          providerCallId:
            envelope.call.call_id,

          providerCallType:
            envelope.call.call_type,

          canonicalCallId:
            canonicalCall.call_id,

          canonicalCallCorrelationId:
            canonicalCall.correlation_id,

          prospectId:
            canonicalCall.prospect_id,

          opportunityId:
            canonicalCall.opportunity_id,

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
          "canonical_call_resolved",

        disposition:
          callResolution.disposition,

        provider_call_id:
          envelope.call.call_id,

        canonical_call_id:
          canonicalCall.call_id,

        canonical_call_status:
          canonicalCall.status,

        request_correlation_id:
          requestCorrelationId,

        call_correlation_id:
          canonicalCall.correlation_id,
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
              ctx.supabaseAdmin,
            );

          break;


        case
          "correct_primary_email_v1":

          result =
            await handleCorrectPrimaryEmail(
              runtimeContext,
              envelope.args,
              ctx.supabaseAdmin,
            );

          break;


        case
          "check_appointment_availability_v1":

          result =
            await handleCheckAppointmentAvailability(
              runtimeContext,
              envelope.args,
              ctx.supabaseAdmin,
            );

          break;


        case
          "create_appointment_v1":

          result =
            await handleCreateAppointment(
              runtimeContext,
              envelope.args,
              ctx.supabaseAdmin,
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
            requestCorrelationId,
          );
      }


      logEvent({
        level: "info",
        event:
          "retell_tool_request_completed",

        request_correlation_id:
          requestCorrelationId,

        call_correlation_id:
          canonicalCall.correlation_id,

        canonical_call_id:
          canonicalCall.call_id,

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