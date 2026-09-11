-- Phase 4
-- Deterministic post-call business-state application.
--
-- Consumes only an already VALID PostCallAnalysisV1 decision.
--
-- DOES:
-- - validate the claimed RETELL_CALL_ANALYZED work item;
-- - resolve canonical call/opportunity internally;
-- - consume the canonical VALID PostCallAnalysisV1;
-- - apply conservative deterministic opportunity updates;
-- - advance ANALYZED -> POST_PROCESSED.
--
-- DOES NOT:
-- - call AI;
-- - accept AI JSON;
-- - trust model-controlled internal IDs;
-- - change booking truth;
-- - change DND/contact eligibility;
-- - automatically mark an opportunity QUALIFIED/DISQUALIFIED;
-- - invent next_action_at;
-- - complete/fail the outbox event.

create or replace function public.apply_post_call_business_state_v1(
    p_outbox_event_id uuid,
    p_worker_id text
)
returns table (
    disposition text,
    next_action text,

    decision_id uuid,
    canonical_call_id uuid,
    prospect_id uuid,
    opportunity_id uuid,

    previous_call_status text,
    current_call_status text,

    previous_lifecycle_state text,
    current_lifecycle_state text,

    previous_qualification_state text,
    current_qualification_state text,

    previous_intent text,
    current_intent text,

    previous_objection text,
    current_objection text,

    review_required boolean,
    review_reasons text[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_prepare record;

    v_call public.calls%rowtype;
    v_opportunity public.opportunities%rowtype;
    v_decision public.ai_decisions%rowtype;

    v_provider_payload_hash text;

    v_analysis jsonb;

    v_ai_intent text;
    v_ai_qualification text;
    v_ai_objection text;

    v_sensitive_topic boolean;
    v_caller_requested_human boolean;

    v_interaction_at timestamptz;

    v_previous_call_status text;

    v_previous_lifecycle text;
    v_current_lifecycle text;

    v_previous_qualification text;
    v_current_qualification text;

    v_previous_intent text;
    v_current_intent text;

    v_previous_objection text;
    v_current_objection text;

    v_intent_conflict boolean := false;

    v_review_required boolean := false;
    v_review_reasons text[] := array[]::text[];
begin
    --------------------------------------------------------------------------
    -- 1. Reuse the proven claimed-event preparation boundary.
    --------------------------------------------------------------------------

    select *
    into v_prepare
    from public.prepare_retell_post_call_analysis_v1(
        p_outbox_event_id,
        p_worker_id
    );


    if not found then
        raise exception
            'post-call preparation returned no result'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 2. Lock canonical call.
    --------------------------------------------------------------------------

    select c.*
    into v_call
    from public.calls as c
    where c.call_id =
        v_prepare.canonical_call_id
    for update;


    if not found then
        raise exception
            'canonical call does not exist'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 3. Resolve immutable provider-evidence hash.
    --------------------------------------------------------------------------

    select rpe.payload_hash
    into v_provider_payload_hash
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id =
        v_prepare.raw_provider_event_id;


    if not found then
        raise exception
            'raw provider evidence does not exist'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 4. Resolve the one canonical VALID PostCallAnalysisV1.
    --------------------------------------------------------------------------

    select ad.*
    into v_decision
    from public.ai_decisions as ad
    where ad.call_id =
            v_call.call_id
      and ad.decision_type =
            'POST_CALL_ANALYSIS'
      and ad.schema_name =
            'PostCallAnalysisV1'
      and ad.schema_version =
            '1.0'
      and ad.validation_state =
            'VALID'
    order by
        ad.created_at asc,
        ad.decision_id asc
    limit 1;


    if not found then
        raise exception
            'canonical VALID PostCallAnalysisV1 decision does not exist'
            using errcode = '22000';
    end if;


    if v_decision.input_hash is distinct from
        v_provider_payload_hash
    then
        raise exception
            'post-call decision does not match authoritative provider evidence'
            using errcode = '22000';
    end if;


    if v_decision.prospect_id is distinct from
        v_call.prospect_id
    then
        raise exception
            'post-call decision prospect does not match canonical call'
            using errcode = '22000';
    end if;


    if v_decision.opportunity_id is distinct from
        v_call.opportunity_id
    then
        raise exception
            'post-call decision opportunity does not match canonical call'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 5. Idempotent completed path.
    --------------------------------------------------------------------------

    if v_call.status = 'POST_PROCESSED' then

        if v_call.opportunity_id is not null then

            select o.*
            into v_opportunity
            from public.opportunities as o
            where o.opportunity_id =
                    v_call.opportunity_id
              and o.prospect_id =
                    v_call.prospect_id;

        end if;


        return query
        select
            'REPLAY'::text,
            'COMPLETE_OUTBOX'::text,

            v_decision.decision_id,
            v_call.call_id,
            v_call.prospect_id,
            v_call.opportunity_id,

            v_call.status,
            v_call.status,

            v_opportunity.lifecycle_state,
            v_opportunity.lifecycle_state,

            v_opportunity.qualification_state,
            v_opportunity.qualification_state,

            v_opportunity.current_intent,
            v_opportunity.current_intent,

            v_opportunity.current_objection,
            v_opportunity.current_objection,

            false,
            array[]::text[];

        return;

    end if;


    --------------------------------------------------------------------------
    -- 6. New business-state application requires ANALYZED.
    --------------------------------------------------------------------------

    if v_call.status <> 'ANALYZED' then
        raise exception
            'canonical call is not ready for post-call business-state application'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 7. Defensive validation of canonical validated output.
    --------------------------------------------------------------------------

    v_analysis :=
        v_decision.validated_output;


    if (
        v_analysis is null
        or jsonb_typeof(v_analysis) <> 'object'
    ) then
        raise exception
            'validated PostCallAnalysisV1 output is invalid'
            using errcode = '22000';
    end if;


    if jsonb_typeof(
        v_analysis -> 'primary_intent'
    ) <> 'string' then
        raise exception
            'validated primary_intent is invalid'
            using errcode = '22000';
    end if;


    if jsonb_typeof(
        v_analysis -> 'qualification_result'
    ) <> 'string' then
        raise exception
            'validated qualification_result is invalid'
            using errcode = '22000';
    end if;


    v_ai_intent :=
        upper(
            btrim(
                v_analysis
                    ->> 'primary_intent'
            )
        );


    v_ai_qualification :=
        upper(
            btrim(
                v_analysis
                    ->> 'qualification_result'
            )
        );


    if v_ai_intent not in (
        'PROFESSIONAL_TRAINING',
        'BUSINESS_PARTNERSHIP',
        'GENERAL_SERVICE',
        'UNKNOWN'
    ) then
        raise exception
            'validated primary_intent is unsupported'
            using errcode = '22000';
    end if;


    if v_ai_qualification not in (
        'QUALIFIED',
        'REVIEW_REQUIRED',
        'UNQUALIFIED',
        'UNKNOWN'
    ) then
        raise exception
            'validated qualification_result is unsupported'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- Optional main objection.
    --------------------------------------------------------------------------

    if (
        v_analysis ? 'main_objection'
        and v_analysis -> 'main_objection'
            <> 'null'::jsonb
    ) then

        if jsonb_typeof(
            v_analysis -> 'main_objection'
        ) <> 'string' then
            raise exception
                'validated main_objection is invalid'
                using errcode = '22000';
        end if;


        v_ai_objection :=
            nullif(
                btrim(
                    v_analysis
                        ->> 'main_objection'
                ),
                ''
            );

    end if;


    --------------------------------------------------------------------------
    -- Safety/review flags.
    --------------------------------------------------------------------------

    if jsonb_typeof(
        v_analysis
            -> 'sensitive_topic_detected'
    ) <> 'boolean' then
        raise exception
            'validated sensitive_topic_detected is invalid'
            using errcode = '22000';
    end if;


    if jsonb_typeof(
        v_analysis
            -> 'caller_requested_human'
    ) <> 'boolean' then
        raise exception
            'validated caller_requested_human is invalid'
            using errcode = '22000';
    end if;


    v_sensitive_topic :=
        (
            v_analysis
                ->> 'sensitive_topic_detected'
        )::boolean;


    v_caller_requested_human :=
        (
            v_analysis
                ->> 'caller_requested_human'
        )::boolean;


    --------------------------------------------------------------------------
    -- 8. Interaction timestamp is provider/canonical evidence, not AI output.
    --------------------------------------------------------------------------

    v_interaction_at :=
        coalesce(
            v_call.ended_at,
            v_call.started_at
        );


    if v_interaction_at is null then
        raise exception
            'canonical call has no authoritative interaction timestamp'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 9. Call-only post-processing remains valid.
    --
    -- A call may legitimately have no resolved opportunity.
    --------------------------------------------------------------------------

    if v_call.opportunity_id is null then

        v_previous_call_status :=
            v_call.status;


        update public.calls as c
        set
            status =
                'POST_PROCESSED',

            updated_at =
                now()
        where c.call_id =
            v_call.call_id;


        return query
        select
            'POST_PROCESSED_NO_OPPORTUNITY'::text,
            'COMPLETE_OUTBOX'::text,

            v_decision.decision_id,
            v_call.call_id,
            v_call.prospect_id,
            null::uuid,

            v_previous_call_status,
            'POST_PROCESSED'::text,

            null::text,
            null::text,

            null::text,
            null::text,

            null::text,
            null::text,

            null::text,
            null::text,

            (
                v_sensitive_topic
                or v_caller_requested_human
            ),

            array_remove(
                array[
                    case
                        when v_sensitive_topic
                        then 'SENSITIVE_TOPIC'
                    end,
                    case
                        when v_caller_requested_human
                        then 'CALLER_REQUESTED_HUMAN'
                    end
                ]::text[],
                null
            );

        return;

    end if;


    --------------------------------------------------------------------------
    -- 10. Resolve and lock canonical opportunity.
    --------------------------------------------------------------------------

    select o.*
    into v_opportunity
    from public.opportunities as o
    where o.opportunity_id =
            v_call.opportunity_id
      and o.prospect_id =
            v_call.prospect_id
    for update;


    if not found then
        raise exception
            'canonical opportunity does not exist or does not match prospect'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 11. Preserve previous state.
    --------------------------------------------------------------------------

    v_previous_call_status :=
        v_call.status;

    v_previous_lifecycle :=
        v_opportunity.lifecycle_state;

    v_previous_qualification :=
        v_opportunity.qualification_state;

    v_previous_intent :=
        v_opportunity.current_intent;

    v_previous_objection :=
        v_opportunity.current_objection;


    --------------------------------------------------------------------------
    -- 12. Lifecycle advancement is based on the real interaction itself,
    --     NOT on the AI recommendation.
    --------------------------------------------------------------------------

    v_current_lifecycle :=
        case
            when v_opportunity.lifecycle_state in (
                'NEW',
                'DORMANT'
            )
                then 'ENGAGED'

            else v_opportunity.lifecycle_state
        end;


    --------------------------------------------------------------------------
    -- 13. Intent application.
    --
    -- UNKNOWN cannot erase known intent.
    -- A new AI intent may fill UNKNOWN.
    -- Conflicting known intents require review rather than overwrite.
    --------------------------------------------------------------------------

    v_current_intent :=
        v_opportunity.current_intent;


    if v_ai_intent = 'UNKNOWN' then
        null;


    elsif v_opportunity.current_intent = 'UNKNOWN' then

        v_current_intent :=
            v_ai_intent;


    elsif v_opportunity.current_intent =
        v_ai_intent
    then
        null;


    else
        v_intent_conflict :=
            true;

        v_review_required :=
            true;

        v_review_reasons :=
            array_append(
                v_review_reasons,
                'INTENT_CONFLICT'
            );

    end if;


    --------------------------------------------------------------------------
    -- 14. Preserve existing objection.
    --
    -- AI may fill a missing objection but does not overwrite an existing
    -- authoritative/manual value automatically.
    --------------------------------------------------------------------------

    v_current_objection :=
        v_opportunity.current_objection;


    if (
        v_current_objection is null
        and v_ai_objection is not null
    ) then
        v_current_objection :=
            v_ai_objection;
    end if;


    --------------------------------------------------------------------------
    -- 15. Safety/human-review signals.
    --------------------------------------------------------------------------

    if v_sensitive_topic then

        v_review_required :=
            true;

        v_review_reasons :=
            array_append(
                v_review_reasons,
                'SENSITIVE_TOPIC'
            );

    end if;


    if v_caller_requested_human then

        v_review_required :=
            true;

        v_review_reasons :=
            array_append(
                v_review_reasons,
                'CALLER_REQUESTED_HUMAN'
            );

    end if;


    --------------------------------------------------------------------------
    -- 16. Qualification policy.
    --
    -- We do NOT automatically convert an AI recommendation into a final
    -- QUALIFIED or DISQUALIFIED opportunity state yet.
    --
    -- Conclusive AI recommendations require deterministic/manual policy
    -- review in this version.
    --------------------------------------------------------------------------

    v_current_qualification :=
        v_opportunity.qualification_state;


    if v_opportunity.qualification_state in (
        'QUALIFIED',
        'DISQUALIFIED'
    ) then
        null;


    elsif v_intent_conflict then

        v_current_qualification :=
            'REVIEW_REQUIRED';


    elsif v_ai_qualification =
        'REVIEW_REQUIRED'
    then

        v_current_qualification :=
            'REVIEW_REQUIRED';

        v_review_required :=
            true;

        v_review_reasons :=
            array_append(
                v_review_reasons,
                'POST_CALL_QUALIFICATION_REVIEW'
            );


    elsif v_ai_qualification in (
        'QUALIFIED',
        'UNQUALIFIED'
    ) then

        v_current_qualification :=
            'REVIEW_REQUIRED';

        v_review_required :=
            true;

        v_review_reasons :=
            array_append(
                v_review_reasons,
                'QUALIFICATION_RECOMMENDATION_REQUIRES_POLICY'
            );


    elsif v_ai_qualification =
        'UNKNOWN'
    then

        if v_opportunity.qualification_state =
            'NOT_STARTED'
        then
            v_current_qualification :=
                'IN_PROGRESS';
        end if;

    end if;


    --------------------------------------------------------------------------
    -- 17. Apply deterministic opportunity state.
    --
    -- next_action_at remains untouched because PostCallAnalysisV1 provides
    -- no authoritative timestamp.
    --------------------------------------------------------------------------

    update public.opportunities as o
    set
        lifecycle_state =
            v_current_lifecycle,

        qualification_state =
            v_current_qualification,

        current_intent =
            v_current_intent,

        current_objection =
            v_current_objection,

        last_activity_at =
            case
                when o.last_activity_at is null
                    then v_interaction_at

                when o.last_activity_at <
                    v_interaction_at
                    then v_interaction_at

                else o.last_activity_at
            end,

        last_contact_at =
            case
                when o.last_contact_at is null
                    then v_interaction_at

                when o.last_contact_at <
                    v_interaction_at
                    then v_interaction_at

                else o.last_contact_at
            end,

        updated_at =
            now()
    where o.opportunity_id =
        v_opportunity.opportunity_id;


    --------------------------------------------------------------------------
    -- 18. Mark canonical call post-processed only after the deterministic
    --     business-state mutation succeeds in the same transaction.
    --------------------------------------------------------------------------

    update public.calls as c
    set
        status =
            'POST_PROCESSED',

        updated_at =
            now()
    where c.call_id =
        v_call.call_id;


    --------------------------------------------------------------------------
    -- 19. Return controlled downstream instruction.
    --------------------------------------------------------------------------

    return query
    select
        case
            when v_review_required
                then 'APPLIED_REVIEW_REQUIRED'
            else 'APPLIED'
        end,

        'COMPLETE_OUTBOX'::text,

        v_decision.decision_id,
        v_call.call_id,
        v_call.prospect_id,
        v_call.opportunity_id,

        v_previous_call_status,
        'POST_PROCESSED'::text,

        v_previous_lifecycle,
        v_current_lifecycle,

        v_previous_qualification,
        v_current_qualification,

        v_previous_intent,
        v_current_intent,

        v_previous_objection,
        v_current_objection,

        v_review_required,
        v_review_reasons;
end;
$function$;


comment on function public.apply_post_call_business_state_v1(
    uuid,
    text
)
is
'Phase 4 deterministic post-call business-state application boundary. Consumes the canonical VALID PostCallAnalysisV1 decision, applies conservative opportunity updates, and advances ANALYZED to POST_PROCESSED. Does not accept AI output or mutate booking truth, DND, eligibility, or outbox state.';


revoke all
on function public.apply_post_call_business_state_v1(
    uuid,
    text
)
from public;


revoke all
on function public.apply_post_call_business_state_v1(
    uuid,
    text
)
from anon;


revoke all
on function public.apply_post_call_business_state_v1(
    uuid,
    text
)
from authenticated;


grant execute
on function public.apply_post_call_business_state_v1(
    uuid,
    text
)
to service_role;