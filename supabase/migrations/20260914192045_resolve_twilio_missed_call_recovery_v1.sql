-- ============================================================================
-- Phase 6B.2
-- Deterministic missed-call identity + SMS eligibility resolution.
--
-- PostgreSQL owns:
--   - caller identity resolution
--   - ambiguity handling
--   - SMS eligibility / DND / revoked-consent enforcement
--   - controlled INBOUND_REQUEST eligibility establishment
--   - READY vs REVIEW_REQUIRED vs BLOCKED decision
--
-- This function DOES NOT send SMS.
-- ============================================================================

create or replace function public.resolve_twilio_missed_call_recovery_v1(
    p_candidate_outbox_event_id uuid
)
returns table (
    decision text,
    reason_code text,
    identity_disposition text,
    resolved_call_id uuid,
    resolved_prospect_id uuid,
    resolved_contact_point_id uuid,
    resolved_eligibility_id uuid,
    normalized_phone text,
    downstream_outbox_event_id uuid
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_candidate public.outbox_events%rowtype;
    v_raw public.raw_provider_events%rowtype;
    v_call public.calls%rowtype;

    v_call_sid text;
    v_phone text;

    v_match_ids uuid[];
    v_match_count integer := 0;

    v_call_prospect_id uuid;
    v_prospect_id uuid;
    v_contact_point_id uuid;
    v_eligibility_id uuid;

    v_identity_disposition text;
    v_decision text;
    v_reason text;

    v_has_any_eligibility boolean := false;
    v_has_current_eligible boolean := false;
    v_has_current_review boolean := false;
    v_has_current_block boolean := false;
    v_has_current_dnd boolean := false;
    v_has_current_revoked boolean := false;
    v_has_current_ineligible boolean := false;

    v_downstream_key text;
    v_downstream_type text;
    v_downstream public.outbox_events%rowtype;

    v_consent_source_event_id text;
begin
    --------------------------------------------------------------------------
    -- 1. Candidate boundary.
    --------------------------------------------------------------------------

    if p_candidate_outbox_event_id is null then
        raise exception
            'candidate outbox event ID is required'
            using errcode = '22023';
    end if;


    select oe.*
    into v_candidate
    from public.outbox_events as oe
    where oe.outbox_event_id =
            p_candidate_outbox_event_id
      and oe.event_type =
            'TWILIO_MISSED_CALL_RECOVERY_CANDIDATE';


    if not found then
        raise exception
            'missed-call recovery candidate was not found'
            using errcode = '22023';
    end if;


    if (
        v_candidate.aggregate_type <> 'CALL'
        or v_candidate.aggregate_id is null
        or v_candidate.source_raw_provider_event_id is null
    ) then
        raise exception
            'missed-call recovery candidate has invalid authoritative context'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 2. Resolve authenticated Twilio source evidence.
    --------------------------------------------------------------------------

    select rpe.*
    into v_raw
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id =
            v_candidate.source_raw_provider_event_id
      and rpe.provider = 'TWILIO'
      and rpe.event_type = 'voice_status'
      and rpe.signature_valid is true;


    if not found then
        raise exception
            'authenticated Twilio source evidence was not found'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 3. Resolve canonical missed call.
    --------------------------------------------------------------------------

    select c.*
    into v_call
    from public.calls as c
    where c.call_id =
            v_candidate.aggregate_id
      and c.provider = 'TWILIO'
    for update;


    if not found then
        raise exception
            'canonical Twilio call was not found'
            using errcode = '22023';
    end if;


    if v_call.direction <> 'INBOUND' then
        raise exception
            'missed-call recovery requires an inbound canonical call'
            using errcode = '22000';
    end if;


    if v_call.call_type <> 'PHONE' then
        raise exception
            'missed-call recovery requires a canonical PHONE call'
            using errcode = '22000';
    end if;


    if v_call.disconnection_reason not in (
        'TWILIO_NO_ANSWER',
        'TWILIO_BUSY',
        'TWILIO_CANCELED',
        'TWILIO_FAILED'
    ) then
        raise exception
            'canonical call is not a missed-call recovery candidate'
            using errcode = '22000';
    end if;


    v_call_sid :=
        v_call.provider_call_id;


    if (
        v_raw.payload ->> 'CallSid'
        is distinct from
        v_call_sid
    ) then
        raise exception
            'Twilio source evidence conflicts with canonical CallSid'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 4. Provider phone boundary.
    --
    -- Existing application identity normalization stores E.164.
    -- Accept Twilio caller identity only when already valid canonical E.164.
    -- Anonymous/special/non-PSTN identities are never guessed.
    --------------------------------------------------------------------------

    v_phone :=
        nullif(
            btrim(
                coalesce(
                    v_raw.payload ->> 'From',
                    ''
                )
            ),
            ''
        );


    if (
        v_phone is null
        or v_phone !~ '^\+[1-9][0-9]{7,14}$'
    ) then
        v_decision :=
            'REVIEW_REQUIRED';

        v_reason :=
            'UNUSABLE_CALLER_PHONE';

        v_identity_disposition :=
            'UNRESOLVED';

    else
        ----------------------------------------------------------------------
        -- 5. Serialize identity/eligibility resolution for this phone.
        ----------------------------------------------------------------------

        perform pg_advisory_xact_lock(
            hashtextextended(
                'TWILIO:MISSED_RECOVERY:' ||
                v_phone,
                0
            )
        );


        ----------------------------------------------------------------------
        -- 6. Resolve exact canonical prospect matches.
        --
        -- Existing project behavior:
        -- merged prospect identities resolve to merged_into_prospect_id.
        ----------------------------------------------------------------------

        select
            array_agg(
                distinct
                case
                    when p.identity_status = 'MERGED'
                        then p.merged_into_prospect_id
                    else p.prospect_id
                end
            )
        into v_match_ids
        from public.contact_points as cp
        join public.prospects as p
          on p.prospect_id =
                cp.prospect_id
        where cp.contact_type = 'PHONE'
          and cp.normalized_value =
                v_phone;


        v_match_count :=
            coalesce(
                cardinality(
                    v_match_ids
                ),
                0
            );


        ----------------------------------------------------------------------
        -- 7. Canonicalize prospect already attached to the call.
        ----------------------------------------------------------------------

        if v_call.prospect_id is not null then
            select
                case
                    when p.identity_status = 'MERGED'
                        then p.merged_into_prospect_id
                    else p.prospect_id
                end
            into v_call_prospect_id
            from public.prospects as p
            where p.prospect_id =
                    v_call.prospect_id;


            if not found then
                raise exception
                    'canonical call prospect could not be resolved'
                    using errcode = '22000';
            end if;
        end if;


        ----------------------------------------------------------------------
        -- 8. Identity resolution.
        ----------------------------------------------------------------------

        if v_match_count > 1 then
            v_decision :=
                'REVIEW_REQUIRED';

            v_reason :=
                'AMBIGUOUS_PHONE_IDENTITY';

            v_identity_disposition :=
                'AMBIGUOUS';


        elsif (
            v_call_prospect_id is not null
            and v_match_count = 1
            and v_match_ids[1] <>
                v_call_prospect_id
        ) then
            v_decision :=
                'REVIEW_REQUIRED';

            v_reason :=
                'CALL_PROSPECT_PHONE_CONFLICT';

            v_identity_disposition :=
                'CONFLICT';


        else
            ------------------------------------------------------------------
            -- 9. Resolve or create canonical prospect.
            ------------------------------------------------------------------

            if v_call_prospect_id is not null then
                v_prospect_id :=
                    v_call_prospect_id;

                v_identity_disposition :=
                    case
                        when v_match_count = 1
                            then 'MATCHED_EXISTING'
                        else 'CALL_CONTEXT_EXISTING'
                    end;


            elsif v_match_count = 1 then
                v_prospect_id :=
                    v_match_ids[1];

                v_identity_disposition :=
                    'MATCHED_EXISTING';


            else
                insert into public.prospects (
                    primary_location_code,
                    identity_status
                )
                values (
                    'UNKNOWN',
                    'ACTIVE'
                )
                returning prospect_id
                into v_prospect_id;

                v_identity_disposition :=
                    'CREATED_NEW';
            end if;


            ------------------------------------------------------------------
            -- 10. Prospect state.
            ------------------------------------------------------------------

            if exists (
                select 1
                from public.prospects as p
                where p.prospect_id =
                        v_prospect_id
                  and p.identity_status =
                        'REVIEW_REQUIRED'
            ) then
                v_decision :=
                    'REVIEW_REQUIRED';

                v_reason :=
                    'PROSPECT_IDENTITY_REVIEW_REQUIRED';

            else
                if not exists (
                    select 1
                    from public.prospects as p
                    where p.prospect_id =
                            v_prospect_id
                      and p.identity_status =
                            'ACTIVE'
                ) then
                    raise exception
                        'resolved prospect is not an active canonical identity'
                        using errcode = '22000';
                end if;


                --------------------------------------------------------------
                -- 11. Resolve/create phone contact point.
                --------------------------------------------------------------

                select cp.contact_point_id
                into v_contact_point_id
                from public.contact_points as cp
                where cp.prospect_id =
                        v_prospect_id
                  and cp.contact_type =
                        'PHONE'
                  and cp.normalized_value =
                        v_phone
                order by
                    cp.is_primary desc,
                    cp.created_at asc
                limit 1;


                if v_contact_point_id is null then
                    insert into public.contact_points (
                        prospect_id,
                        contact_type,
                        raw_value,
                        normalized_value,
                        is_primary,
                        verification_state
                    )
                    values (
                        v_prospect_id,
                        'PHONE',
                        v_phone,
                        v_phone,

                        not exists (
                            select 1
                            from public.contact_points as existing_cp
                            where existing_cp.prospect_id =
                                    v_prospect_id
                              and existing_cp.contact_type =
                                    'PHONE'
                        ),

                        'UNVERIFIED'
                    )
                    returning contact_point_id
                    into v_contact_point_id;
                end if;


                --------------------------------------------------------------
                -- 12. Attach authoritative identity to canonical call.
                --------------------------------------------------------------

                update public.calls as c
                set prospect_id =
                    v_prospect_id
                where c.call_id =
                    v_call.call_id
                  and (
                      c.prospect_id is null
                      or c.prospect_id =
                            v_call.prospect_id
                      or c.prospect_id =
                            v_prospect_id
                  );


                --------------------------------------------------------------
                -- 13. Evaluate BOTH eligibility scopes.
                --
                -- Safety precedence:
                --
                -- BLOCKED
                --   > REVIEW_REQUIRED
                --   > ELIGIBLE
                --
                -- A contact-specific eligible record therefore cannot bypass
                -- a prospect-level DND/revocation.
                --------------------------------------------------------------

                select
                    count(*) > 0,

                    coalesce(
                        bool_or(
                            ce.dnd is true
                            and ce.effective_at <= now()
                            and (
                                ce.expires_at is null
                                or ce.expires_at >= now()
                            )
                        ),
                        false
                    ),

                    coalesce(
                        bool_or(
                            ce.consent_basis = 'REVOKED'
                            and ce.effective_at <= now()
                            and (
                                ce.expires_at is null
                                or ce.expires_at >= now()
                            )
                        ),
                        false
                    ),

                    coalesce(
                        bool_or(
                            ce.eligibility_state = 'INELIGIBLE'
                            and ce.effective_at <= now()
                            and (
                                ce.expires_at is null
                                or ce.expires_at >= now()
                            )
                        ),
                        false
                    ),

                    coalesce(
                        bool_or(
                            ce.eligibility_state = 'REVIEW_REQUIRED'
                            and ce.effective_at <= now()
                            and (
                                ce.expires_at is null
                                or ce.expires_at >= now()
                            )
                        ),
                        false
                    ),

                    coalesce(
                        bool_or(
                            ce.eligibility_state = 'ELIGIBLE'
                            and ce.dnd is false
                            and ce.consent_basis <> 'REVOKED'
                            and ce.effective_at <= now()
                            and (
                                ce.expires_at is null
                                or ce.expires_at >= now()
                            )
                        ),
                        false
                    )
                into
                    v_has_any_eligibility,
                    v_has_current_dnd,
                    v_has_current_revoked,
                    v_has_current_ineligible,
                    v_has_current_review,
                    v_has_current_eligible
                from public.contact_eligibility as ce
                where ce.prospect_id =
                        v_prospect_id
                  and ce.channel =
                        'SMS'
                  and ce.purpose =
                        'INBOUND_RESPONSE'
                  and (
                      ce.contact_point_id is null
                      or ce.contact_point_id =
                            v_contact_point_id
                  );


                v_has_current_block :=
                    v_has_current_dnd
                    or v_has_current_revoked
                    or v_has_current_ineligible;


                --------------------------------------------------------------
                -- 14. Existing state decision.
                --------------------------------------------------------------

                if v_has_current_block then
                    v_decision :=
                        'BLOCKED';

                    v_reason :=
                        case
                            when v_has_current_dnd
                                then 'DND'
                            when v_has_current_revoked
                                then 'CONSENT_REVOKED'
                            else 'SMS_INELIGIBLE'
                        end;


                elsif v_has_current_review then
                    v_decision :=
                        'REVIEW_REQUIRED';

                    v_reason :=
                        'SMS_ELIGIBILITY_REVIEW_REQUIRED';


                elsif v_has_current_eligible then
                    select ce.eligibility_id
                    into v_eligibility_id
                    from public.contact_eligibility as ce
                    where ce.prospect_id =
                            v_prospect_id
                      and ce.channel =
                            'SMS'
                      and ce.purpose =
                            'INBOUND_RESPONSE'
                      and (
                          ce.contact_point_id is null
                          or ce.contact_point_id =
                                v_contact_point_id
                      )
                      and ce.eligibility_state =
                            'ELIGIBLE'
                      and ce.dnd is false
                      and ce.consent_basis <>
                            'REVOKED'
                      and ce.effective_at <=
                            now()
                      and (
                          ce.expires_at is null
                          or ce.expires_at >=
                                now()
                      )
                    order by
                        case
                            when ce.contact_point_id =
                                v_contact_point_id
                                then 0
                            else 1
                        end,
                        ce.effective_at desc
                    limit 1;


                    v_decision :=
                        'RECOVERY_READY';

                    v_reason :=
                        'EXISTING_SMS_ELIGIBILITY';


                elsif v_has_any_eligibility then
                    ----------------------------------------------------------
                    -- Existing rows exist, but none provide a current,
                    -- affirmative permission state.
                    --
                    -- Do not silently replace expired/future eligibility.
                    ----------------------------------------------------------

                    v_decision :=
                        'REVIEW_REQUIRED';

                    v_reason :=
                        'ELIGIBILITY_NOT_CURRENT';


                else
                    ----------------------------------------------------------
                    -- 15. Fresh inbound request.
                    --
                    -- No contrary eligibility state exists.
                    -- Establish only SMS / INBOUND_RESPONSE eligibility.
                    -- This is NOT explicit marketing consent.
                    ----------------------------------------------------------

                    insert into public.contact_eligibility (
                        prospect_id,
                        contact_point_id,
                        channel,
                        purpose,
                        eligibility_state,
                        dnd,
                        consent_basis,
                        provenance_source,
                        provenance_reference,
                        reason_code,
                        effective_at
                    )
                    values (
                        v_prospect_id,
                        v_contact_point_id,
                        'SMS',
                        'INBOUND_RESPONSE',
                        'ELIGIBLE',
                        false,
                        'INBOUND_REQUEST',
                        'TWILIO_MISSED_CALL',
                        v_call_sid,
                        'MISSED_CALL_INBOUND_REQUEST',
                        now()
                    )
                    on conflict (
                        prospect_id,
                        contact_point_id,
                        channel,
                        purpose
                    )
                    where contact_point_id is not null
                    do nothing
                    returning eligibility_id
                    into v_eligibility_id;


                    if v_eligibility_id is null then
                        ------------------------------------------------------
                        -- Advisory locking should normally prevent this race,
                        -- but resolve defensively without overwriting.
                        ------------------------------------------------------

                        select ce.eligibility_id
                        into v_eligibility_id
                        from public.contact_eligibility as ce
                        where ce.prospect_id =
                                v_prospect_id
                          and ce.contact_point_id =
                                v_contact_point_id
                          and ce.channel =
                                'SMS'
                          and ce.purpose =
                                'INBOUND_RESPONSE'
                        limit 1;


                        if v_eligibility_id is null then
                            raise exception
                                'SMS eligibility race could not be resolved'
                                using errcode = 'P0001';
                        end if;


                        select
                            case
                                when ce.dnd is true
                                  or ce.consent_basis = 'REVOKED'
                                  or ce.eligibility_state = 'INELIGIBLE'
                                    then 'BLOCKED'

                                when ce.eligibility_state = 'ELIGIBLE'
                                  and ce.effective_at <= now()
                                  and (
                                      ce.expires_at is null
                                      or ce.expires_at >= now()
                                  )
                                    then 'RECOVERY_READY'

                                else 'REVIEW_REQUIRED'
                            end,

                            case
                                when ce.dnd is true
                                    then 'DND'

                                when ce.consent_basis = 'REVOKED'
                                    then 'CONSENT_REVOKED'

                                when ce.eligibility_state = 'INELIGIBLE'
                                    then 'SMS_INELIGIBLE'

                                when ce.eligibility_state = 'ELIGIBLE'
                                  and ce.effective_at <= now()
                                  and (
                                      ce.expires_at is null
                                      or ce.expires_at >= now()
                                  )
                                    then 'EXISTING_SMS_ELIGIBILITY'

                                else 'ELIGIBILITY_RACE_REVIEW_REQUIRED'
                            end
                        into
                            v_decision,
                            v_reason
                        from public.contact_eligibility as ce
                        where ce.eligibility_id =
                                v_eligibility_id;

                    else
                        ------------------------------------------------------
                        -- 16. Append provenance exactly once.
                        ------------------------------------------------------

                        v_consent_source_event_id :=
                            'twilio-missed-call:' ||
                            v_call_sid ||
                            ':sms-inbound-response-eligibility';


                        insert into public.consent_events (
                            prospect_id,
                            contact_point_id,
                            channel,
                            purpose,
                            action,
                            source,
                            source_event_id,
                            evidence_reference,
                            evidence_summary,
                            occurred_at
                        )
                        values (
                            v_prospect_id,
                            v_contact_point_id,
                            'SMS',
                            'INBOUND_RESPONSE',
                            'ELIGIBILITY_REVIEWED',
                            'TWILIO_MISSED_CALL',
                            v_consent_source_event_id,
                            v_raw.raw_provider_event_id::text,
                            'Inbound missed call established INBOUND_REQUEST basis for controlled recovery response.',
                            v_raw.received_at
                        )
                        on conflict (
                            source,
                            source_event_id
                        )
                        where source_event_id is not null
                        do nothing;


                        v_decision :=
                            'RECOVERY_READY';

                        v_reason :=
                            'FRESH_INBOUND_REQUEST';
                    end if;
                end if;
            end if;
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 17. READY or REVIEW creates deterministic downstream work.
    --
    -- BLOCKED is terminal here. Phase 6C must independently re-check current
    -- eligibility immediately before any provider transport operation.
    --------------------------------------------------------------------------

    if v_decision = 'RECOVERY_READY' then
        v_downstream_key :=
            'TWILIO:CALL:' ||
            v_call_sid ||
            ':MISSED_RECOVERY_READY';

        v_downstream_type :=
            'TWILIO_MISSED_CALL_RECOVERY_READY';


    elsif v_decision = 'REVIEW_REQUIRED' then
        v_downstream_key :=
            'TWILIO:CALL:' ||
            v_call_sid ||
            ':MISSED_RECOVERY_REVIEW_REQUIRED';

        v_downstream_type :=
            'TWILIO_MISSED_CALL_RECOVERY_REVIEW_REQUIRED';
    end if;


    if v_downstream_key is not null then
        insert into public.outbox_events (
            event_key,
            event_type,
            aggregate_type,
            aggregate_id,
            source_raw_provider_event_id,
            correlation_id,
            payload
        )
        values (
            v_downstream_key,
            v_downstream_type,
            'CALL',
            v_call.call_id,
            v_raw.raw_provider_event_id,
            v_call.correlation_id,
            jsonb_build_object(
                'provider',
                'TWILIO',

                'provider_call_id',
                v_call_sid,

                'call_id',
                v_call.call_id,

                'prospect_id',
                v_prospect_id,

                'contact_point_id',
                v_contact_point_id,

                'normalized_phone',
                v_phone,

                'decision',
                v_decision,

                'reason_code',
                v_reason,

                'eligibility_id',
                v_eligibility_id,

                'raw_provider_event_id',
                v_raw.raw_provider_event_id
            )
        )
        on conflict on constraint outbox_events_event_key_unique
        do nothing
        returning *
        into v_downstream;


        if not found then
            select oe.*
            into v_downstream
            from public.outbox_events as oe
            where oe.event_key =
                    v_downstream_key;


            if not found then
                raise exception
                    'missed-call recovery decision replay could not be resolved'
                    using errcode = 'P0001';
            end if;


            if (
                v_downstream.aggregate_id
                    is distinct from
                v_call.call_id
            ) then
                raise exception
                    'missed-call recovery decision conflicts with canonical call'
                    using errcode = '22000';
            end if;
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 18. Return authoritative decision.
    --------------------------------------------------------------------------

    return query
    select
        v_decision,
        v_reason,
        v_identity_disposition,
        v_call.call_id,
        v_prospect_id,
        v_contact_point_id,
        v_eligibility_id,
        v_phone,
        v_downstream.outbox_event_id;
end;
$function$;


comment on function public.resolve_twilio_missed_call_recovery_v1(uuid)
is
'Phase 6B.2 deterministic missed-call identity and SMS eligibility resolver. Exact phone identity, prospect/contact DND, revoked consent, and current eligibility remain authoritative. Emits READY or REVIEW work but never sends SMS.';


revoke all
on function public.resolve_twilio_missed_call_recovery_v1(uuid)
from public;

revoke all
on function public.resolve_twilio_missed_call_recovery_v1(uuid)
from anon;

revoke all
on function public.resolve_twilio_missed_call_recovery_v1(uuid)
from authenticated;

grant execute
on function public.resolve_twilio_missed_call_recovery_v1(uuid)
to service_role;