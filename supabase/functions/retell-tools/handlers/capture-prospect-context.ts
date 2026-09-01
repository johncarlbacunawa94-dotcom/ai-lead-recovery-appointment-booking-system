import type {
  SupabaseClient,
} from "npm:@supabase/supabase-js@^2";

import type {
  ToolRuntimeContext,
} from "../../_shared/tool-runtime-context.ts";

import {
  normalizeCaptureArguments,
} from "../../_shared/capture-normalization.ts";

import {
  acquireToolExecution,
  buildToolRequestIdentity,
  completeToolExecution,
} from "../../_shared/tool-idempotency.ts";


type CaptureRpcResult = {
  status:
    | "RESOLVED"
    | "REVIEW_REQUIRED"
    | "ERROR";

  prospect_id:
    | string
    | null;

  opportunity_id:
    | string
    | null;

  identity_resolution:
    | "CREATED"
    | "EXACT_MATCH"
    | "AMBIGUOUS"
    | "INSUFFICIENT_IDENTITY";

  opportunity_resolution:
    | "CREATED"
    | "EXISTING"
    | "AMBIGUOUS"
    | "NOT_RESOLVED";

  current_lifecycle_state:
    | "NEW"
    | "ENGAGED"
    | "QUALIFYING"
    | "QUALIFIED"
    | "BOOKING_READY"
    | "BOOKED"
    | "DORMANT"
    | "WON"
    | "LOST"
    | "CLOSED"
    | null;

  error_code:
    | string
    | null;
};


function technicalErrorResponse(
  context: ToolRuntimeContext,
  correlationId: string,
): Record<string, unknown> {

  return {
    status:
      "ERROR",

    correlation_id:
      correlationId,

    prospect_id:
      context.prospectId,

    opportunity_id:
      context.opportunityId,

    identity_resolution:
      context.prospectId
        ? "EXACT_MATCH"
        : "INSUFFICIENT_IDENTITY",

    current_lifecycle_state:
      null,

    allowed_actions: [
      "REQUEST_HANDOFF",
    ],

    error_code:
      "INTERNAL_ERROR",

    message_for_agent:
      "Lead context could not be saved safely. Do not claim it was saved. Request human follow-up.",

    retryable:
      false,
  };
}


function mapResolvedActions(
  lifecycle:
    CaptureRpcResult[
      "current_lifecycle_state"
    ],
): string[] {

  if (
    lifecycle ===
      "BOOKING_READY"
  ) {
    return [
      "CHECK_AVAILABILITY",
    ];
  }


  if (
    lifecycle ===
      "BOOKED"
  ) {
    return [
      "NONE",
    ];
  }


  return [
    "CONTINUE_QUALIFICATION",
  ];
}


function mapRpcResult(
  row: CaptureRpcResult,
  correlationId: string,
): Record<string, unknown> {

  if (
    row.status ===
      "RESOLVED"
  ) {

    let message =
      "Lead context is saved. Continue with the approved qualification flow.";


    if (
      row.current_lifecycle_state ===
        "BOOKING_READY"
    ) {
      message =
        "Lead context is saved and booking-ready. You may check appointment availability.";
    }


    if (
      row.current_lifecycle_state ===
        "BOOKED"
    ) {
      message =
        "Lead context is saved and this opportunity is already booked. Do not create a duplicate booking.";
    }


    return {
      status:
        "RESOLVED",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        row.opportunity_id,

      identity_resolution:
        row.identity_resolution,

      current_lifecycle_state:
        row.current_lifecycle_state,

      allowed_actions:
        mapResolvedActions(
          row.current_lifecycle_state,
        ),

      error_code:
        null,

      message_for_agent:
        message,

      retryable:
        false,
    };
  }


  if (
    row.error_code ===
      "INSUFFICIENT_IDENTITY"
  ) {
    return {
      status:
        "REVIEW_REQUIRED",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        row.opportunity_id,

      identity_resolution:
        "INSUFFICIENT_IDENTITY",

      current_lifecycle_state:
        row.current_lifecycle_state,

      allowed_actions: [
        "ASK_FOR_IDENTITY",
      ],

      error_code:
        "INSUFFICIENT_IDENTITY",

      message_for_agent:
        "Ask for a valid email address or phone number before continuing. Do not claim the lead was saved.",

      retryable:
        false,
    };
  }


  if (
    row.error_code ===
      "IDENTITY_AMBIGUOUS"
  ) {
    return {
      status:
        "REVIEW_REQUIRED",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        row.opportunity_id,

      identity_resolution:
        "AMBIGUOUS",

      current_lifecycle_state:
        row.current_lifecycle_state,

      allowed_actions: [
        "REQUEST_HANDOFF",
      ],

      error_code:
        "IDENTITY_AMBIGUOUS",

      message_for_agent:
        "The contact details match conflicting or multiple records. Do not guess which record is correct. Request human follow-up.",

      retryable:
        false,
    };
  }


  if (
    row.error_code ===
      "OPPORTUNITY_STATE_CONFLICT"
  ) {
    return {
      status:
        "REVIEW_REQUIRED",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        null,

      identity_resolution:
        row.identity_resolution,

      current_lifecycle_state:
        null,

      allowed_actions: [
        "REQUEST_HANDOFF",
      ],

      error_code:
        "OPPORTUNITY_STATE_CONFLICT",

      message_for_agent:
        "More than one active opportunity could match this enquiry. Do not choose one automatically. Request human follow-up.",

      retryable:
        false,
    };
  }


  return {
    status:
      "ERROR",

    correlation_id:
      correlationId,

    prospect_id:
      row.prospect_id,

    opportunity_id:
      row.opportunity_id,

    identity_resolution:
      row.identity_resolution,

    current_lifecycle_state:
      row.current_lifecycle_state,

    allowed_actions: [
      "REQUEST_HANDOFF",
    ],

    error_code:
      row.error_code ??
      "INTERNAL_ERROR",

    message_for_agent:
      "Lead context could not be resolved safely. Do not claim it was saved. Request human follow-up.",

    retryable:
      false,
  };
}


export async function handleCaptureProspectContext(
  context: ToolRuntimeContext,

  args:
    Record<string, unknown>,

  supabaseAdmin:
    SupabaseClient,

): Promise<Record<string, unknown>> {

  const normalized =
    normalizeCaptureArguments(
      args,
    );


  const {
    requestHash,
    idempotencyKey,
  } = await buildToolRequestIdentity(
    context.providerCallId,

    "capture_prospect_context_v1",

    normalized.hashArguments,
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
          "capture_prospect_context_v1",

        requestHash,
        idempotencyKey,

        requestPayload:
          normalized.hashArguments,
      },
    );


  if (!execution.ok) {
    return technicalErrorResponse(
      context,
      context.correlationId,
    );
  }


  if (
    execution.cachedResponse
  ) {
    return execution.cachedResponse;
  }


  const executionCorrelationId =
    execution.record
      .correlation_id;


  const {
    data,
    error,
  } = await supabaseAdmin
    .rpc(
      "resolve_capture_context_v1",

      {
        p_call_id:
          context.canonicalCallId,

        p_first_name:
          normalized.firstName,

        p_last_name:
          normalized.lastName,

        p_company_name:
          normalized.companyName,

        p_email_raw:
          normalized.emailRaw,

        p_email_normalized:
          normalized.emailNormalized,

        p_phone_raw:
          normalized.phoneRaw,

        p_phone_normalized:
          normalized.phoneNormalized,

        p_location_code:
          normalized.locationCode,

        p_stated_intent:
          normalized.statedIntent,
      },
    )
    .single();


  if (
    error ||
    !data
  ) {
    const response =
      technicalErrorResponse(
        context,
        executionCorrelationId,
      );


    const completed =
      await completeToolExecution(
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


    if (!completed) {
      console.error(
        JSON.stringify({
          event:
            "capture_tool_execution_finalize_failed",

          tool_execution_id:
            execution.record
              .tool_execution_id,

          canonical_call_id:
            context.canonicalCallId,
        }),
      );
    }


    return response;
  }


  const rpcResult =
    data as CaptureRpcResult;


  const response =
    mapRpcResult(
      rpcResult,
      executionCorrelationId,
    );


  const operationalOutcome =
    rpcResult.status ===
      "ERROR"
      ? "FAILED"
      : "SUCCEEDED";


  const completed =
    await completeToolExecution(
      supabaseAdmin,
      {
        toolExecutionId:
          execution.record
            .tool_execution_id,

        prospectId:
          rpcResult.prospect_id,

        opportunityId:
          rpcResult.opportunity_id,

        response,

        outcome:
          operationalOutcome,

        errorCode:
          rpcResult.error_code,
      },
    );


  if (!completed) {
    console.error(
      JSON.stringify({
        event:
          "capture_tool_execution_finalize_failed",

        tool_execution_id:
          execution.record
            .tool_execution_id,

        canonical_call_id:
          context.canonicalCallId,
      }),
    );
  }


  return response;
}