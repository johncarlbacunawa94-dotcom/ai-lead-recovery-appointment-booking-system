-- Phase 4
-- Deterministic validation + persistence boundary for PostCallAnalysisV1.
--
-- Responsibilities:
-- - verify claimed RETELL_CALL_ANALYZED work through the proven
--   prepare_retell_post_call_analysis_v1 boundary;
-- - validate PostCallAnalysisV1 deterministically;
-- - audit every AI result in ai_decisions;
-- - persist only validated call-level analytical state;
-- - advance canonical call ANALYSIS_PENDING -> ANALYZED.
--
-- Explicitly DOES NOT:
-- - call AI;
-- - trust model-supplied internal IDs;
-- - mutate opportunities;
-- - mutate booking truth;
-- - mutate DND/contact eligibility;
-- - complete or fail the outbox event.

create unique index if not exists
    ai_decisions_post_call_analysis_v1_valid_unique
on public.ai_decisions (
    call_id,
    schema_name,
    schema_version
)
where decision_type = 'POST_CALL_ANALYSIS'
  and validation_state = 'VALID';


create or replace function public.persist_post_call_analysis_v1(
    p_outbox_event_id uuid,
    p_worker_id text,
    p_ai_provider text,
    p_model text,
    p_prompt_version text,
    p_raw_output jsonb
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

    validation_state text,
    validation_errors jsonb,
    validated_output jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_prepare record;

    v_call public.calls%rowtype;
    v_raw public.raw_provider_events%rowtype;

    v_existing public.ai_decisions%rowtype;
    v_decision public.ai_decisions%rowtype;

    v_ai_provider text;
    v_model text;
    v_prompt_version text;

    v_errors jsonb := '[]'::jsonb;
    v_validated jsonb;

    v_summary text;
    v_primary_intent text;
    v_qualification_result text;
    v_main_objection text;

    v_questions jsonb;
    v_unresolved jsonb;

    v_sensitive boolean;
    v_human_requested boolean;

    v_booking_discussed boolean;
    v_booking_outcome text;

    v_recommended_next_action text;
    v_follow_up_required boolean;

    v_confidence numeric;

    v_key text;
    v_item text;
    v_item_json jsonb;

    v_previous_status text;
begin
    --------------------------------------------------------------------------
    -- 1. Validate AI execution metadata.
    --------------------------------------------------------------------------

    v_ai_provider :=
        nullif(
            upper(
                btrim(
                    coalesce(
                        p_ai_provider,
                        ''
                    )
                )
            ),
            ''
        );


    if v_ai_provider is null then
        raise exception
            'AI provider is required'
            using errcode = '22023';
    end if;


    if char_length(v_ai_provider) > 100 then
        raise exception
            'AI provider exceeds maximum length'
            using errcode = '22023';
    end if;


    v_model :=
        nullif(
            btrim(
                coalesce(
                    p_model,
                    ''
                )
            ),
            ''
        );


    if v_model is null then
        raise exception
            'AI model is required'
            using errcode = '22023';
    end if;


    if char_length(v_model) > 200 then
        raise exception
            'AI model exceeds maximum length'
            using errcode = '22023';
    end if;


    v_prompt_version :=
        nullif(
            btrim(
                coalesce(
                    p_prompt_version,
                    ''
                )
            ),
            ''
        );


    if v_prompt_version is null then
        raise exception
            'prompt version is required'
            using errcode = '22023';
    end if;


    if char_length(v_prompt_version) > 200 then
        raise exception
            'prompt version exceeds maximum length'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 2. Reuse the proven preparation boundary.
    --
    -- This verifies:
    -- - RETELL_CALL_ANALYZED
    -- - PROCESSING lease
    -- - worker ownership
    -- - authenticated raw provider evidence
    -- - canonical call binding
    -- - permitted analysis lifecycle state
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
    -- 3. Resolve and lock authoritative canonical state.
    --------------------------------------------------------------------------

    select c.*
    into v_call
    from public.calls as c
    where c.call_id =
        v_prepare.canonical_call_id
    for update;


    if not found then
        raise exception
            'canonical call disappeared during persistence'
            using errcode = '22000';
    end if;


    select rpe.*
    into v_raw
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id =
        v_prepare.raw_provider_event_id;


    if not found then
        raise exception
            'raw provider evidence disappeared during persistence'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 4. Idempotent valid-decision replay.
    --
    -- One VALID PostCallAnalysisV1 per call/schema version is canonical.
    --------------------------------------------------------------------------

    select ad.*
    into v_existing
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


    if found then

        if v_existing.input_hash is distinct from
            v_raw.payload_hash
        then
            raise exception
                'existing post-call analysis belongs to different provider evidence'
                using errcode = '22000';
        end if;


        if v_call.status = 'POST_PROCESSED' then

            return query
            select
                'REPLAY'::text,
                'COMPLETE_OUTBOX'::text,

                v_existing.decision_id,
                v_call.call_id,
                v_call.prospect_id,
                v_call.opportunity_id,

                v_call.status,
                v_call.status,

                v_existing.validation_state,
                v_existing.validation_errors,
                v_existing.validated_output;

            return;


        elsif v_call.status = 'ANALYZED' then

            return query
            select
                'REPLAY'::text,
                'APPLY_POST_CALL_BUSINESS_STATE'::text,

                v_existing.decision_id,
                v_call.call_id,
                v_call.prospect_id,
                v_call.opportunity_id,

                v_call.status,
                v_call.status,

                v_existing.validation_state,
                v_existing.validation_errors,
                v_existing.validated_output;

            return;


        else
            raise exception
                'valid post-call decision exists but canonical call is not analyzed'
                using errcode = '22000';
        end if;

    end if;


    --------------------------------------------------------------------------
    -- 5. New AI output may only be persisted from ANALYSIS_PENDING.
    --------------------------------------------------------------------------

    if v_call.status <> 'ANALYSIS_PENDING' then
        raise exception
            'canonical call is not awaiting post-call analysis'
            using errcode = '22000';
    end if;


    if v_prepare.evidence_ready is distinct from true then
        raise exception
            'authoritative post-call evidence is not ready'
            using errcode = '22000';
    end if;


    if v_prepare.next_action is distinct from
        'RUN_POST_CALL_ANALYSIS'
    then
        raise exception
            'post-call preparation did not authorize analysis'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 6. Top-level contract.
    --
    -- A malformed/non-object output is audited as INVALID.
    -- Field-level validation only runs when the root is an object.
    --------------------------------------------------------------------------

    if (
        p_raw_output is null
        or jsonb_typeof(p_raw_output) <> 'object'
    ) then

        v_errors :=
            v_errors ||
            jsonb_build_array(
                'raw_output must be a JSON object'
            );

    else

        ----------------------------------------------------------------------
        -- 7. Reject unknown fields.
        ----------------------------------------------------------------------

        for v_key in
            select jsonb_object_keys(
                p_raw_output
            )
        loop

            if v_key <> all(
                array[
                    'summary',
                    'primary_intent',
                    'qualification_result',
                    'main_objection',
                    'questions_asked',
                    'unresolved_questions',
                    'sensitive_topic_detected',
                    'caller_requested_human',
                    'booking_discussed',
                    'booking_outcome',
                    'recommended_next_action',
                    'follow_up_required',
                    'confidence'
                ]::text[]
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'unknown field: ' ||
                        v_key
                    );

            end if;

        end loop;


        ----------------------------------------------------------------------
        -- 8. summary
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'summary'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'summary is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'summary'
        ) <> 'string' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'summary must be a string'
                );


        else

            v_summary :=
                btrim(
                    p_raw_output ->> 'summary'
                );


            if (
                v_summary = ''
                or char_length(v_summary) > 2000
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'summary must contain 1 to 2000 characters'
                    );

            end if;

        end if;


        ----------------------------------------------------------------------
        -- 9. primary_intent
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'primary_intent'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'primary_intent is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'primary_intent'
        ) <> 'string' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'primary_intent must be a string'
                );


        else

            v_primary_intent :=
                upper(
                    btrim(
                        p_raw_output
                            ->> 'primary_intent'
                    )
                );


            if v_primary_intent not in (
                'PROFESSIONAL_TRAINING',
                'BUSINESS_PARTNERSHIP',
                'GENERAL_SERVICE',
                'UNKNOWN'
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'primary_intent is unsupported'
                    );

            end if;

        end if;


        ----------------------------------------------------------------------
        -- 10. qualification_result
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'qualification_result'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'qualification_result is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'qualification_result'
        ) <> 'string' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'qualification_result must be a string'
                );


        else

            v_qualification_result :=
                upper(
                    btrim(
                        p_raw_output
                            ->> 'qualification_result'
                    )
                );


            if v_qualification_result not in (
                'QUALIFIED',
                'REVIEW_REQUIRED',
                'UNQUALIFIED',
                'UNKNOWN'
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'qualification_result is unsupported'
                    );

            end if;

        end if;


        ----------------------------------------------------------------------
        -- 11. main_objection
        --
        -- Required field, but JSON null is permitted.
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'main_objection'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'main_objection is required, but may be null'
                );


        elsif (
            p_raw_output -> 'main_objection'
        ) = 'null'::jsonb then

            v_main_objection :=
                null;


        elsif jsonb_typeof(
            p_raw_output -> 'main_objection'
        ) <> 'string' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'main_objection must be a string or null'
                );


        else

            v_main_objection :=
                nullif(
                    btrim(
                        p_raw_output
                            ->> 'main_objection'
                    ),
                    ''
                );


            if (
                v_main_objection is not null
                and char_length(
                    v_main_objection
                ) > 1000
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'main_objection exceeds 1000 characters'
                    );

            end if;

        end if;


        ----------------------------------------------------------------------
        -- 12. questions_asked[]
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'questions_asked'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'questions_asked is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'questions_asked'
        ) <> 'array' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'questions_asked must be an array'
                );


        else

            if jsonb_array_length(
                p_raw_output -> 'questions_asked'
            ) > 25 then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'questions_asked may contain at most 25 items'
                    );

            end if;


            for v_item_json in
                select value
                from jsonb_array_elements(
                    p_raw_output
                        -> 'questions_asked'
                )
            loop

                if jsonb_typeof(
                    v_item_json
                ) <> 'string' then

                    v_errors :=
                        v_errors ||
                        jsonb_build_array(
                            'questions_asked items must be strings'
                        );


                else

                    v_item :=
                        v_item_json #>> '{}';


                    if (
                        btrim(v_item) = ''
                        or char_length(
                            btrim(v_item)
                        ) > 500
                    ) then

                        v_errors :=
                            v_errors ||
                            jsonb_build_array(
                                'questions_asked contains an invalid item'
                            );

                    end if;

                end if;

            end loop;

        end if;


        ----------------------------------------------------------------------
        -- 13. unresolved_questions[]
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'unresolved_questions'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'unresolved_questions is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'unresolved_questions'
        ) <> 'array' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'unresolved_questions must be an array'
                );


        else

            if jsonb_array_length(
                p_raw_output
                    -> 'unresolved_questions'
            ) > 25 then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'unresolved_questions may contain at most 25 items'
                    );

            end if;


            for v_item_json in
                select value
                from jsonb_array_elements(
                    p_raw_output
                        -> 'unresolved_questions'
                )
            loop

                if jsonb_typeof(
                    v_item_json
                ) <> 'string' then

                    v_errors :=
                        v_errors ||
                        jsonb_build_array(
                            'unresolved_questions items must be strings'
                        );


                else

                    v_item :=
                        v_item_json #>> '{}';


                    if (
                        btrim(v_item) = ''
                        or char_length(
                            btrim(v_item)
                        ) > 500
                    ) then

                        v_errors :=
                            v_errors ||
                            jsonb_build_array(
                                'unresolved_questions contains an invalid item'
                            );

                    end if;

                end if;

            end loop;

        end if;


        ----------------------------------------------------------------------
        -- 14. sensitive_topic_detected
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'sensitive_topic_detected'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'sensitive_topic_detected is required'
                );


        elsif jsonb_typeof(
            p_raw_output
                -> 'sensitive_topic_detected'
        ) <> 'boolean' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'sensitive_topic_detected must be boolean'
                );


        else

            v_sensitive :=
                (
                    p_raw_output
                        ->> 'sensitive_topic_detected'
                )::boolean;

        end if;


        ----------------------------------------------------------------------
        -- 15. caller_requested_human
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'caller_requested_human'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'caller_requested_human is required'
                );


        elsif jsonb_typeof(
            p_raw_output
                -> 'caller_requested_human'
        ) <> 'boolean' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'caller_requested_human must be boolean'
                );


        else

            v_human_requested :=
                (
                    p_raw_output
                        ->> 'caller_requested_human'
                )::boolean;

        end if;


        ----------------------------------------------------------------------
        -- 16. booking_discussed
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'booking_discussed'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'booking_discussed is required'
                );


        elsif jsonb_typeof(
            p_raw_output
                -> 'booking_discussed'
        ) <> 'boolean' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'booking_discussed must be boolean'
                );


        else

            v_booking_discussed :=
                (
                    p_raw_output
                        ->> 'booking_discussed'
                )::boolean;

        end if;


        ----------------------------------------------------------------------
        -- 17. booking_outcome
        --
        -- Analytical evidence only.
        -- It never writes calls.appointment_result.
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'booking_outcome'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'booking_outcome is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'booking_outcome'
        ) <> 'string' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'booking_outcome must be a string'
                );


        else

            v_booking_outcome :=
                upper(
                    btrim(
                        p_raw_output
                            ->> 'booking_outcome'
                    )
                );


            if v_booking_outcome not in (
                'NOT_DISCUSSED',
                'DISCUSSED_NO_BOOKING',
                'AVAILABILITY_CHECKED',
                'BOOKED',
                'SLOT_UNAVAILABLE',
                'HUMAN_REQUIRED',
                'FAILED',
                'UNKNOWN'
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'booking_outcome is unsupported'
                    );

            end if;

        end if;


        ----------------------------------------------------------------------
        -- 18. Booking cross-field consistency.
        ----------------------------------------------------------------------

        if (
            v_booking_discussed is false
            and v_booking_outcome is not null
            and v_booking_outcome not in (
                'NOT_DISCUSSED',
                'UNKNOWN'
            )
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'booking_outcome conflicts with booking_discussed=false'
                );

        end if;


        if (
            v_booking_discussed is true
            and v_booking_outcome =
                'NOT_DISCUSSED'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'booking_outcome conflicts with booking_discussed=true'
                );

        end if;


        ----------------------------------------------------------------------
        -- 19. recommended_next_action
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'recommended_next_action'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'recommended_next_action is required'
                );


        elsif jsonb_typeof(
            p_raw_output
                -> 'recommended_next_action'
        ) <> 'string' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'recommended_next_action must be a string'
                );


        else

            v_recommended_next_action :=
                btrim(
                    p_raw_output
                        ->> 'recommended_next_action'
                );


            if (
                v_recommended_next_action = ''
                or char_length(
                    v_recommended_next_action
                ) > 1000
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'recommended_next_action must contain 1 to 1000 characters'
                    );

            end if;

        end if;


        ----------------------------------------------------------------------
        -- 20. follow_up_required
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'follow_up_required'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'follow_up_required is required'
                );


        elsif jsonb_typeof(
            p_raw_output
                -> 'follow_up_required'
        ) <> 'boolean' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'follow_up_required must be boolean'
                );


        else

            v_follow_up_required :=
                (
                    p_raw_output
                        ->> 'follow_up_required'
                )::boolean;

        end if;


        ----------------------------------------------------------------------
        -- 21. confidence
        ----------------------------------------------------------------------

        if not (
            p_raw_output ? 'confidence'
        ) then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'confidence is required'
                );


        elsif jsonb_typeof(
            p_raw_output -> 'confidence'
        ) <> 'number' then

            v_errors :=
                v_errors ||
                jsonb_build_array(
                    'confidence must be numeric'
                );


        else

            v_confidence :=
                (
                    p_raw_output
                        ->> 'confidence'
                )::numeric;


            if (
                v_confidence < 0
                or v_confidence > 1
            ) then

                v_errors :=
                    v_errors ||
                    jsonb_build_array(
                        'confidence must be between 0 and 1'
                    );

            end if;

        end if;

    end if;


    --------------------------------------------------------------------------
    -- 22. INVALID output.
    --
    -- Audit it, but mutate no call/business state.
    --------------------------------------------------------------------------

    if jsonb_array_length(
        v_errors
    ) > 0 then

        insert into public.ai_decisions (
            prospect_id,
            opportunity_id,
            call_id,

            decision_type,
            provider,
            model,

            schema_name,
            schema_version,
            prompt_version,

            input_hash,

            raw_output,
            validated_output,
            confidence,

            validation_state,
            validation_errors,

            knowledge_source_codes
        )
        values (
            v_call.prospect_id,
            v_call.opportunity_id,
            v_call.call_id,

            'POST_CALL_ANALYSIS',
            v_ai_provider,
            v_model,

            'PostCallAnalysisV1',
            '1.0',
            v_prompt_version,

            v_raw.payload_hash,

            p_raw_output,
            null,
            null,

            'INVALID',
            v_errors,

            array[]::text[]
        )
        returning *
        into v_decision;


        return query
        select
            'INVALID'::text,
            'FAIL_OUTBOX'::text,

            v_decision.decision_id,
            v_call.call_id,
            v_call.prospect_id,
            v_call.opportunity_id,

            v_call.status,
            v_call.status,

            v_decision.validation_state,
            v_decision.validation_errors,
            null::jsonb;

        return;

    end if;


    --------------------------------------------------------------------------
    -- 23. Normalize arrays while preserving source order.
    --
    -- At this point each element has already been proven to be a JSON string.
    --------------------------------------------------------------------------

    select coalesce(
        jsonb_agg(
            to_jsonb(
                btrim(e.value)
            )
            order by e.ordinality
        ),
        '[]'::jsonb
    )
    into v_questions
    from jsonb_array_elements_text(
        p_raw_output
            -> 'questions_asked'
    )
    with ordinality as e(
        value,
        ordinality
    );


    select coalesce(
        jsonb_agg(
            to_jsonb(
                btrim(e.value)
            )
            order by e.ordinality
        ),
        '[]'::jsonb
    )
    into v_unresolved
    from jsonb_array_elements_text(
        p_raw_output
            -> 'unresolved_questions'
    )
    with ordinality as e(
        value,
        ordinality
    );


    --------------------------------------------------------------------------
    -- 24. Build the normalized validated PostCallAnalysisV1 object.
    --------------------------------------------------------------------------

    v_validated :=
        jsonb_build_object(
            'summary',
                v_summary,

            'primary_intent',
                v_primary_intent,

            'qualification_result',
                v_qualification_result,

            'main_objection',
                v_main_objection,

            'questions_asked',
                v_questions,

            'unresolved_questions',
                v_unresolved,

            'sensitive_topic_detected',
                v_sensitive,

            'caller_requested_human',
                v_human_requested,

            'booking_discussed',
                v_booking_discussed,

            'booking_outcome',
                v_booking_outcome,

            'recommended_next_action',
                v_recommended_next_action,

            'follow_up_required',
                v_follow_up_required,

            'confidence',
                v_confidence
        );


    --------------------------------------------------------------------------
    -- 25. Audit VALID AI decision.
    --------------------------------------------------------------------------

    insert into public.ai_decisions (
        prospect_id,
        opportunity_id,
        call_id,

        decision_type,
        provider,
        model,

        schema_name,
        schema_version,
        prompt_version,

        input_hash,

        raw_output,
        validated_output,
        confidence,

        validation_state,
        validation_errors,

        knowledge_source_codes
    )
    values (
        v_call.prospect_id,
        v_call.opportunity_id,
        v_call.call_id,

        'POST_CALL_ANALYSIS',
        v_ai_provider,
        v_model,

        'PostCallAnalysisV1',
        '1.0',
        v_prompt_version,

        v_raw.payload_hash,

        p_raw_output,
        v_validated,
        v_confidence,

        'VALID',
        '[]'::jsonb,

        array[]::text[]
    )
    returning *
    into v_decision;


    --------------------------------------------------------------------------
    -- 26. Persist call-level analytical state.
    --
    -- Booking truth is deliberately untouched.
    -- Opportunity state is deliberately untouched.
    --------------------------------------------------------------------------

    v_previous_status :=
        v_call.status;


    update public.calls as c
    set
        summary =
            v_summary,

        detected_intent =
            v_primary_intent,

        qualification_result =
            v_qualification_result,

        post_call_analysis =
            v_validated,

        status =
            'ANALYZED',

        updated_at =
            now()
    where c.call_id =
        v_call.call_id;


    --------------------------------------------------------------------------
    -- 27. Return controlled downstream instruction.
    --------------------------------------------------------------------------

    return query
    select
        'PERSISTED'::text,
        'APPLY_POST_CALL_BUSINESS_STATE'::text,

        v_decision.decision_id,
        v_call.call_id,
        v_call.prospect_id,
        v_call.opportunity_id,

        v_previous_status,
        'ANALYZED'::text,

        v_decision.validation_state,
        v_decision.validation_errors,
        v_decision.validated_output;
end;
$function$;


comment on function public.persist_post_call_analysis_v1(
    uuid,
    text,
    text,
    text,
    text,
    jsonb
)
is
'Phase 4 deterministic PostCallAnalysisV1 validation and persistence boundary. Resolves internal context server-side, audits AI output, mutates only call-level analytical state, and advances ANALYSIS_PENDING to ANALYZED. Does not mutate opportunity lifecycle, booking truth, DND, eligibility, or outbox state.';


revoke all
on function public.persist_post_call_analysis_v1(
    uuid,
    text,
    text,
    text,
    text,
    jsonb
)
from public;


revoke all
on function public.persist_post_call_analysis_v1(
    uuid,
    text,
    text,
    text,
    text,
    jsonb
)
from anon;


revoke all
on function public.persist_post_call_analysis_v1(
    uuid,
    text,
    text,
    text,
    text,
    jsonb
)
from authenticated;


grant execute
on function public.persist_post_call_analysis_v1(
    uuid,
    text,
    text,
    text,
    text,
    jsonb
)
to service_role;