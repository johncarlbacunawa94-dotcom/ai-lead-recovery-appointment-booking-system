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


type HandoffReason =
  | "EXPLICIT_HUMAN_REQUEST"
  | "SENSITIVE_OR_CLINICAL"
  | "LOW_CONFIDENCE"
  | "UNSUPPORTED_KNOWLEDGE"
  | "HIGH_VALUE_OPPORTUNITY"
  | "CALLER_FRUSTRATION"
  | "BOOKING_FAILURE"
  | "TOOL_FAILURE"
  | "CONFLICTING_INTENT"
  | "OUT_OF_SCOPE";


type ActiveHandoff = {
  handoff_id: string;

  transfer_mode:
    | "NONE"
    | "QUEUE_ONLY"
    | "WARM"
    | "COLD";

  transfer_destination_alias:
    | string
    | null;

  handoff_status:
    | "OPEN"
    | "CLAIMED";
};


function normalizeBriefContext(
  value: unknown,
): string | null {

  if (
    typeof value !== "string"
  ) {
    return null;
  }


  const normalized =
    value.trim();


  return normalized.length > 0
    ? normalized
    : null;
}


function priorityForReason(
  reasonCode: HandoffReason,
):
  | "LOW"
  | "NORMAL"
  | "HIGH"
  | "CRITICAL" {

  switch (reasonCode) {

    case "SENSITIVE_OR_CLINICAL":
    case "HIGH_VALUE_OPPORTUNITY":
    case "CALLER_FRUSTRATION":
    case "BOOKING_FAILURE":
    case "TOOL_FAILURE":

      return "HIGH";


    default:

      return "NORMAL";
  }
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

    handoff_id:
      null,

    transfer_mode:
      "NONE",

    transfer_destination_alias:
      null,

    allowed_actions: [
      "END_CONVERSATION",
    ],

    error_code:
      "INTERNAL_ERROR",

    message_for_agent:
      "Human follow-up could not be queued safely. Do not claim that a transfer or handoff was created. End the conversation safely.",

    retryable:
      false,
  };
}


function queuedResponse(
  correlationId: string,
  handoff: ActiveHandoff,
): Record<string, unknown> {

  return {
    status:
      "QUEUE_ONLY",

    correlation_id:
      correlationId,

    handoff_id:
      handoff.handoff_id,

    transfer_mode:
      handoff.transfer_mode,

    transfer_destination_alias:
      handoff.transfer_destination_alias,

    allowed_actions: [
      "END_CONVERSATION",
    ],

    error_code:
      null,

    message_for_agent:
      "Human follow-up has been queued. Do not claim that a live transfer occurred. Acknowledge the request and end the conversation safely.",

    retryable:
      false,
  };
}


function alreadyRequestedResponse(
  correlationId: string,
  handoff: ActiveHandoff,
): Record<string, unknown> {

  return {
    status:
      "ALREADY_REQUESTED",

    correlation_id:
      correlationId,

    handoff_id:
      handoff.handoff_id,

    transfer_mode:
      handoff.transfer_mode,

    transfer_destination_alias:
      handoff.transfer_destination_alias,

    allowed_actions: [
      "END_CONVERSATION",
    ],

    error_code:
      "HANDOFF_ALREADY_ACTIVE",

    message_for_agent:
      "Human follow-up is already queued for this reason. Do not create another handoff or claim that a live transfer occurred. End the conversation safely.",

    retryable:
      false,
  };
}


function replayCachedResponse(
  response:
    Record<string, unknown>,
): Record<string, unknown> {

  if (
    (
      response.status !==
        "QUEUE_ONLY"
    ) &&
    (
      response.status !==
        "ALREADY_REQUESTED"
    )
  ) {
    return response;
  }


  return {
    ...response,

    status:
      "ALREADY_REQUESTED",

    error_code:
      "HANDOFF_ALREADY_ACTIVE",

    message_for_agent:
      "Human follow-up is already queued for this reason. Do not create another handoff or claim that a live transfer occurred. End the conversation safely.",
  };
}


async function findActiveHandoff(
  supabaseAdmin: SupabaseClient,
  callId: string,
  reasonCode: HandoffReason,
): Promise<
  | {
      ok: true;
      handoff:
        ActiveHandoff | null;
    }
  | {
      ok: false;
    }
> {

  const {
    data,
    error,
  } = await supabaseAdmin
    .from(
      "human_handoffs",
    )
    .select(
      [
        "handoff_id",
        "transfer_mode",
        "transfer_destination_alias",
        "handoff_status",
      ].join(","),
    )
    .eq(
      "call_id",
      callId,
    )
    .eq(
      "reason_code",
      reasonCode,
    )
    .in(
      "handoff_status",
      [
        "OPEN",
        "CLAIMED",
      ],
    )
    .order(
      "requested_at",
      {
        ascending:
          true,
      },
    )
    .limit(1)
    .maybeSingle();


  if (error) {
    return {
      ok:
        false,
    };
  }


  return {
    ok:
      true,

    handoff:
      data
        ? data as ActiveHandoff
        : null,
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
      | "FAILED";

    errorCode:
      | string
      | null;

    canonicalCallId:
      string;
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
          "handoff_tool_execution_finalize_failed",

        tool_execution_id:
          input.toolExecutionId,

        canonical_call_id:
          input.canonicalCallId,
      }),
    );
  }
}


export async function handleHumanHandoff(
  context: ToolRuntimeContext,

  args:
    Record<string, unknown>,

  supabaseAdmin:
    SupabaseClient,

): Promise<Record<string, unknown>> {

  const reasonCode = args.reason_code as HandoffReason;


  const callerRequested =
    args.caller_requested ===
      true;


  const briefContext =
    normalizeBriefContext(
      args.brief_context,
    );


  const normalizedArguments:
    Record<string, unknown> = {

      reason_code:
        reasonCode,

      caller_requested:
        callerRequested,

      brief_context:
        briefContext,
    };


  const {
    requestHash,
    idempotencyKey,
  } = await buildToolRequestIdentity(
    context.providerCallId,

    "request_human_handoff_v1",

    normalizedArguments,
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
          "request_human_handoff_v1",

        requestHash,
        idempotencyKey,

        requestPayload:
          normalizedArguments,
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
    return replayCachedResponse(
      execution.cachedResponse,
    );
  }


  const correlationId =
    execution.record
      .correlation_id;


  // ------------------------------------------------------------
  // Domain-level idempotency.
  //
  // The active handoff uniqueness rule is:
  //
  // canonical call + reason_code
  //
  // This remains independent of tool-execution request hashing.
  // ------------------------------------------------------------

  const existing =
    await findActiveHandoff(
      supabaseAdmin,
      context.canonicalCallId,
      reasonCode,
    );


  if (!existing.ok) {

    const response =
      technicalErrorResponse(
        context,
        correlationId,
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

        canonicalCallId:
          context.canonicalCallId,
      },
    );


    return response;
  }


  if (
    existing.handoff
  ) {

    const response =
      alreadyRequestedResponse(
        correlationId,
        existing.handoff,
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
          "SUCCEEDED",

        errorCode:
          null,

        canonicalCallId:
          context.canonicalCallId,
      },
    );


    return response;
  }


  // ------------------------------------------------------------
  // Phase 5 transfer policy.
  //
  // Web-call acceptance proves detection, queue creation and
  // handoff contract only.
  //
  // Live PSTN transfer is intentionally NOT claimed here.
  // Until Phase 6 telephony is implemented, every handoff is
  // queue-only.
  // ------------------------------------------------------------

  const {
    data: inserted,
    error: insertError,
  } = await supabaseAdmin
    .from(
      "human_handoffs",
    )
    .insert({
      prospect_id:
        context.prospectId,

      opportunity_id:
        context.opportunityId,

      call_id:
        context.canonicalCallId,

      conversation_id:
        null,

      source_channel:
        "VOICE",

      reason_code:
        reasonCode,

      priority:
        priorityForReason(
          reasonCode,
        ),

      requested_by:
        callerRequested
          ? "CALLER"
          : "AI",

      conversation_summary:
        briefContext,

      sensitive_topic_detected:
        reasonCode ===
          "SENSITIVE_OR_CLINICAL",

      caller_explicitly_requested_human:
        callerRequested,

      recommended_next_action:
        "Human review and follow-up.",

      transfer_mode:
        "QUEUE_ONLY",

      transfer_destination_alias:
        null,

      transfer_result:
        "QUEUED",

      handoff_status:
        "OPEN",
    })
    .select(
      [
        "handoff_id",
        "transfer_mode",
        "transfer_destination_alias",
        "handoff_status",
      ].join(","),
    )
    .single();


  let handoff:
    ActiveHandoff | null =
      null;


  let alreadyExisting =
    false;


  if (
    !insertError &&
    inserted
  ) {
    handoff =
      inserted as ActiveHandoff;
  } else if (
    insertError?.code ===
      "23505"
  ) {

    // Concurrent equivalent request won the race.
    // Resolve the already-created active handoff instead of
    // creating a duplicate side effect.

    const racedExisting =
      await findActiveHandoff(
        supabaseAdmin,
        context.canonicalCallId,
        reasonCode,
      );


    if (
      !racedExisting.ok ||
      !racedExisting.handoff
    ) {

      const response =
        technicalErrorResponse(
          context,
          correlationId,
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

          canonicalCallId:
            context.canonicalCallId,
        },
      );


      return response;
    }


    handoff =
      racedExisting.handoff;

    alreadyExisting =
      true;

  } else {

    const response =
      technicalErrorResponse(
        context,
        correlationId,
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

        canonicalCallId:
          context.canonicalCallId,
      },
    );


    return response;
  }


  const response =
    alreadyExisting
      ? alreadyRequestedResponse(
          correlationId,
          handoff,
        )
      : queuedResponse(
          correlationId,
          handoff,
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
        "SUCCEEDED",

      errorCode:
        null,

      canonicalCallId:
        context.canonicalCallId,
    },
  );


  return response;
}