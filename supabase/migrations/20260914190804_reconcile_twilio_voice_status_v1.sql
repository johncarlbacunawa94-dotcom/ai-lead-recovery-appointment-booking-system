-- ============================================================================
-- Phase 6B.1
-- Deterministic Twilio inbound voice-status reconciliation.
--
-- PostgreSQL owns:
--   - authoritative Twilio voice-event ordering
--   - canonical inbound Twilio call state
--   - deterministic missed-call classification
--   - transactional creation of the recovery-candidate outbox event
--
-- n8n does not decide whether a call was missed.
-- ============================================================================

create or replace function public.reconcile_twilio_voice_status_v1(
    p_raw_provider_event_id uuid
)
returns table (
    disposition text,
    call_id uuid,
    provider_call_id text,
    provider_status text,
    sequence_number integer,
    canonical_status text,
    missed_recovery_candidate boolean,
    recovery_outbox_event_id uuid
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_source public.raw_provider_events%rowtype;
    v_latest public.raw_provider_events%rowtype;

    v_call_sid text;
    v_source_sequence integer;
    v_latest_sequence integer;

    v_direction text;
    v_status text;
    v_from text;
    v_to text;

    v_target_status text;
    v_disconnection_reason text;

    v_existing public.calls%rowtype;
    v_result public.calls%rowtype;

    v_candidate boolean := false;
    v_candidate_key text;
    v_candidate_outbox public.outbox_events%rowtype;

    v_disposition text;
begin
    --------------------------------------------------------------------------
    -- 1. Invocation boundary.
    --------------------------------------------------------------------------

    if p_raw_provider_event_id is null then
        raise exception
            'raw provider event ID is required'
            using errcode = '22023';
    end if;


    select rpe.*
    into v_source
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id =
            p_raw_provider_event_id
      and rpe.provider = 'TWILIO'
      and rpe.event_type = 'voice_status'
      and rpe.signature_valid is true;


    if not found then
        raise exception
            'authenticated Twilio voice-status event was not found'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 2. Validate source event identity.
    --------------------------------------------------------------------------

    v_call_sid :=
        nullif(
            btrim(
                coalesce(
                    v_source.payload ->> 'CallSid',
                    ''
                )
            ),
            ''
        );


    if v_call_sid is null then
        raise exception
            'Twilio voice-status evidence has no CallSid'
            using errcode = '22023';
    end if;


    begin
        v_source_sequence :=
            (
                v_source.payload ->> 'SequenceNumber'
            )::integer;
    exception
        when invalid_text_representation then
            raise exception
                'Twilio voice-status SequenceNumber is invalid'
                using errcode = '22023';
    end;


    if (
        v_source_sequence is null
        or v_source_sequence < 0
    ) then
        raise exception
            'Twilio voice-status SequenceNumber must be non-negative'
            using errcode = '22023';
    end if;


    if v_source.event_key <>
        (
            'TWILIO:CALL:' ||
            v_call_sid ||
            ':STATUS:' ||
            v_source_sequence::text
        )
    then
        raise exception
            'Twilio raw event key conflicts with provider payload'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 3. Serialize reconciliation for this Twilio CallSid.
    --------------------------------------------------------------------------

    perform pg_advisory_xact_lock(
        hashtextextended(
            'TWILIO:' ||
            v_call_sid,
            0
        )
    );


    --------------------------------------------------------------------------
    -- 4. Resolve provider-authoritative latest evidence.
    --
    -- Twilio status callbacks may arrive out of order. Arrival time is not
    -- authoritative. SequenceNumber is.
    --------------------------------------------------------------------------

    select rpe.*
    into v_latest
    from public.raw_provider_events as rpe
    where rpe.provider = 'TWILIO'
      and rpe.event_type = 'voice_status'
      and rpe.signature_valid is true
      and rpe.payload ->> 'CallSid' =
            v_call_sid
      and coalesce(
            rpe.payload ->> 'SequenceNumber',
            ''
          ) ~ '^[0-9]+$'
    order by
        (
            rpe.payload ->> 'SequenceNumber'
        )::integer desc,
        rpe.received_at desc
    limit 1;


    if not found then
        raise exception
            'latest Twilio voice-status evidence could not be resolved'
            using errcode = 'P0001';
    end if;


    v_latest_sequence :=
        (
            v_latest.payload ->> 'SequenceNumber'
        )::integer;


    v_direction :=
        lower(
            btrim(
                coalesce(
                    v_latest.payload ->> 'Direction',
                    ''
                )
            )
        );


    v_status :=
        lower(
            btrim(
                coalesce(
                    v_latest.payload ->> 'CallStatus',
                    ''
                )
            )
        );


    v_from :=
        nullif(
            btrim(
                coalesce(
                    v_latest.payload ->> 'From',
                    ''
                )
            ),
            ''
        );


    v_to :=
        nullif(
            btrim(
                coalesce(
                    v_latest.payload ->> 'To',
                    ''
                )
            ),
            ''
        );


    --------------------------------------------------------------------------
    -- 5. Phase 6B owns inbound missed-call recovery only.
    --------------------------------------------------------------------------

    if v_direction <> 'inbound' then
        return query
        select
            'IGNORED_NON_INBOUND'::text,
            null::uuid,
            v_call_sid,
            v_status,
            v_latest_sequence,
            null::text,
            false,
            null::uuid;

        return;
    end if;


    --------------------------------------------------------------------------
    -- 6. Deterministic Twilio -> canonical call-state mapping.
    --------------------------------------------------------------------------

    case v_status
        when 'queued' then
            v_target_status :=
                'ACTIVE';

            v_disconnection_reason :=
                null;


        when 'ringing' then
            v_target_status :=
                'ACTIVE';

            v_disconnection_reason :=
                null;


        when 'in-progress' then
            v_target_status :=
                'ACTIVE';

            v_disconnection_reason :=
                null;


        when 'completed' then
            v_target_status :=
                'ENDED';

            v_disconnection_reason :=
                'TWILIO_COMPLETED';


        when 'no-answer' then
            v_target_status :=
                'ENDED';

            v_disconnection_reason :=
                'TWILIO_NO_ANSWER';

            v_candidate :=
                true;


        when 'busy' then
            v_target_status :=
                'ENDED';

            v_disconnection_reason :=
                'TWILIO_BUSY';

            v_candidate :=
                true;


        when 'canceled' then
            v_target_status :=
                'ENDED';

            v_disconnection_reason :=
                'TWILIO_CANCELED';

            v_candidate :=
                true;


        when 'failed' then
            v_target_status :=
                'FAILED';

            v_disconnection_reason :=
                'TWILIO_FAILED';

            v_candidate :=
                true;


        else
            raise exception
                'unsupported Twilio CallStatus: %',
                v_status
                using errcode = '22023';
    end case;


    --------------------------------------------------------------------------
    -- 7. Resolve or create canonical Twilio call.
    --------------------------------------------------------------------------

    select c.*
    into v_existing
    from public.calls as c
    where c.provider =
            'TWILIO'
      and c.provider_call_id =
            v_call_sid
    for update;


    if not found then
        insert into public.calls (
            correlation_id,
            provider,
            telephony_provider,
            provider_call_id,
            call_type,
            direction,
            status,
            disconnection_reason
        )
        values (
            v_latest.correlation_id,
            'TWILIO',
            'TWILIO',
            v_call_sid,
            'PHONE',
            'INBOUND',
            v_target_status,
            v_disconnection_reason
        )
        returning *
        into v_result;


        v_disposition :=
            'CREATED';
    else
        ----------------------------------------------------------------------
        -- Existing canonical identity is authoritative.
        ----------------------------------------------------------------------

        if v_existing.call_type <> 'PHONE' then
            raise exception
                'Twilio CallSid conflicts with canonical call type'
                using errcode = '22000';
        end if;


        if v_existing.direction <> 'INBOUND' then
            raise exception
                'Twilio CallSid conflicts with canonical call direction'
                using errcode = '22000';
        end if;


        update public.calls as c
        set
            telephony_provider =
                coalesce(
                    c.telephony_provider,
                    'TWILIO'
                ),

            status =
                v_target_status,

            disconnection_reason =
                v_disconnection_reason
        where c.call_id =
            v_existing.call_id
        returning c.*
        into v_result;


        if (
            v_existing.status is distinct from
                v_result.status
            or
            v_existing.disconnection_reason is distinct from
                v_result.disconnection_reason
        ) then
            v_disposition :=
                'UPDATED';
        else
            v_disposition :=
                'EXISTING';
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 8. Deterministic missed-call recovery candidate.
    --
    -- This is not permission to send SMS yet.
    -- Phase 6B.2 must resolve identity and contact eligibility first.
    --------------------------------------------------------------------------

    if v_candidate then
        v_candidate_key :=
            'TWILIO:CALL:' ||
            v_call_sid ||
            ':MISSED_RECOVERY_CANDIDATE';


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
            v_candidate_key,
            'TWILIO_MISSED_CALL_RECOVERY_CANDIDATE',
            'CALL',
            v_result.call_id,
            v_latest.raw_provider_event_id,
            v_result.correlation_id,
            jsonb_build_object(
                'provider',
                'TWILIO',

                'provider_call_id',
                v_call_sid,

                'provider_status',
                v_status,

                'sequence_number',
                v_latest_sequence,

                'from',
                v_from,

                'to',
                v_to,

                'call_id',
                v_result.call_id,

                'raw_provider_event_id',
                v_latest.raw_provider_event_id
            )
        )
        on conflict on constraint outbox_events_event_key_unique
        do nothing
        returning *
        into v_candidate_outbox;


        if not found then
            select oe.*
            into v_candidate_outbox
            from public.outbox_events as oe
            where oe.event_key =
                v_candidate_key;


            if not found then
                raise exception
                    'missed-call recovery candidate replay could not be resolved'
                    using errcode = 'P0001';
            end if;


            if (
                v_candidate_outbox.aggregate_id
                    is distinct from
                v_result.call_id
            ) then
                raise exception
                    'recovery candidate conflicts with canonical call'
                    using errcode = '22000';
            end if;
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 9. Return authoritative result.
    --------------------------------------------------------------------------

    return query
    select
        v_disposition,
        v_result.call_id,
        v_call_sid,
        v_status,
        v_latest_sequence,
        v_result.status,
        v_candidate,
        v_candidate_outbox.outbox_event_id;
end;
$function$;


comment on function public.reconcile_twilio_voice_status_v1(uuid)
is
'Phase 6B.1 deterministic Twilio inbound voice reconciliation. Resolves the highest authenticated SequenceNumber for a CallSid, maintains canonical call state, and emits at most one missed-call recovery candidate. Does not authorize SMS delivery.';


-- ============================================================================
-- Trusted execution boundary.
-- ============================================================================

revoke all
on function public.reconcile_twilio_voice_status_v1(uuid)
from public;

revoke all
on function public.reconcile_twilio_voice_status_v1(uuid)
from anon;

revoke all
on function public.reconcile_twilio_voice_status_v1(uuid)
from authenticated;

grant execute
on function public.reconcile_twilio_voice_status_v1(uuid)
to service_role;