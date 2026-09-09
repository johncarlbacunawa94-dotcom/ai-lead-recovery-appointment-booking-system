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


type CorrectionRpcResult = {
  status:
    | "CORRECTED"
    | "ALREADY_CURRENT"
    | "REVIEW_REQUIRED"
    | "ERROR";

  prospect_id:
    | string
    | null;

  opportunity_id:
    | string
    | null;

  corrected_contact_point_id:
    | string
    | null;

  previous_primary_contact_point_id:
    | string
    | null;

  error_code:
    | string
    | null;
};


type NormalizedCorrection = {
  emailRaw: string;
  emailNormalized: string;

  hashArguments: {
    corrected_email: string;
  };
};


function normalizeCorrectedEmail(
  value: unknown,
): NormalizedCorrection | null {

  if (
    typeof value !== "string"
  ) {
    return null;
  }


  const emailRaw =
    value
      .normalize("NFKC")
      .trim();


  const emailNormalized =
    emailRaw
      .toLocaleLowerCase(
        "en-AU",
      );


  if (
    emailNormalized.length === 0 ||
    emailNormalized.length > 320 ||
    /\s/.test(
      emailNormalized,
    )
  ) {
    return null;
  }


  const parts =
    emailNormalized.split("@");


  if (
    parts.length !== 2
  ) {
    return null;
  }


  const [
    localPart,
    domainPart,
  ] = parts;


  if (
    localPart.length === 0 ||
    domainPart.length === 0 ||
    !domainPart.includes(".") ||
    domainPart.startsWith(".") ||
    domainPart.endsWith(".")
  ) {
    return null;
  }


  return {
    emailRaw,
    emailNormalized,

    hashArguments: {
      corrected_email:
        emailNormalized,
    },
  };
}


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

    allowed_actions: [
      "REQUEST_HANDOFF",
    ],

    error_code:
      "INTERNAL_ERROR",

    message_for_agent:
      "The email correction could not be saved safely. Do not claim it was saved. Request human follow-up.",

    retryable:
      false,
  };
}


function invalidEmailResponse(
  context: ToolRuntimeContext,
  correlationId: string,
): Record<string, unknown> {

  return {
    status:
      "REVIEW_REQUIRED",

    correlation_id:
      correlationId,

    prospect_id:
      context.prospectId,

    opportunity_id:
      context.opportunityId,

    allowed_actions: [
      "ASK_FOR_IDENTITY",
    ],

    error_code:
      "INVALID_EMAIL",

    message_for_agent:
      "Ask the caller for the corrected email address again. Do not claim the correction was saved.",

    retryable:
      false,
  };
}


function mapRpcResult(
  row: CorrectionRpcResult,
  correlationId: string,
): Record<string, unknown> {

  if (
    row.status ===
      "CORRECTED"
  ) {
    return {
      status:
        "CORRECTED",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        row.opportunity_id,

      allowed_actions: [
        "CONTINUE_QUALIFICATION",
      ],

      error_code:
        null,

      message_for_agent:
        "The corrected email is saved. Continue with the approved conversation flow.",

      retryable:
        false,
    };
  }


  if (
    row.status ===
      "ALREADY_CURRENT"
  ) {
    return {
      status:
        "ALREADY_CURRENT",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        row.opportunity_id,

      allowed_actions: [
        "CONTINUE_QUALIFICATION",
      ],

      error_code:
        null,

      message_for_agent:
        "That email is already the current primary email. Continue with the approved conversation flow.",

      retryable:
        false,
    };
  }


  if (
    row.error_code ===
      "INVALID_EMAIL"
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

      allowed_actions: [
        "ASK_FOR_IDENTITY",
      ],

      error_code:
        "INVALID_EMAIL",

      message_for_agent:
        "Ask the caller for the corrected email address again. Do not claim the correction was saved.",

      retryable:
        false,
    };
  }


  if (
    row.status ===
      "REVIEW_REQUIRED"
  ) {

    let message =
      "The email correction cannot be applied safely. Do not guess or change contact ownership. Request human follow-up.";


    if (
      row.error_code ===
        "EMAIL_OWNERSHIP_CONFLICT"
    ) {
      message =
        "The corrected email conflicts with another contact record. Do not reassign it. Request human follow-up.";
    }


    if (
      row.error_code ===
        "BOOKED_CONTACT_CHANGE_REQUIRES_HUMAN"
    ) {
      message =
        "The contact is already tied to booking state that requires human reconciliation. Request human follow-up.";
    }


    return {
      status:
        "REVIEW_REQUIRED",

      correlation_id:
        correlationId,

      prospect_id:
        row.prospect_id,

      opportunity_id:
        row.opportunity_id,

      allowed_actions: [
        "REQUEST_HANDOFF",
      ],

      error_code:
        row.error_code,

      message_for_agent:
        message,

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

    allowed_actions: [
      "REQUEST_HANDOFF",
    ],

    error_code:
      row.error_code ??
      "INTERNAL_ERROR",

    message_for_agent:
      "The email correction could not be saved safely. Do not claim it was saved. Request human follow-up.",

    retryable:
      false,
  };
}


export async function handleCorrectPrimaryEmail(
  context: ToolRuntimeContext,

  args:
    Record<string, unknown>,

  supabaseAdmin:
    SupabaseClient,

): Promise<Record<string, unknown>> {

  const normalized =
    normalizeCorrectedEmail(
      args.corrected_email,
    );


  if (!normalized) {
    return invalidEmailResponse(
      context,
      context.correlationId,
    );
  }


  const {
    requestHash,
    idempotencyKey,
  } = await buildToolRequestIdentity(
    context.providerCallId,

    "correct_primary_email_v1",

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
          "correct_primary_email_v1",

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
      "correct_primary_email_v1",

      {
        p_call_id:
          context.canonicalCallId,

        p_email_raw:
          normalized.emailRaw,

        p_email_normalized:
          normalized.emailNormalized,
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
            "correct_email_tool_execution_finalize_failed",

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
    data as CorrectionRpcResult;


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
          "correct_email_tool_execution_finalize_failed",

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
