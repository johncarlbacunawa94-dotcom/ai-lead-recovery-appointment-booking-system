-- ============================================================================
-- Phase 6C.1
-- Pre-send boundary for Twilio missed-call recovery SMS.
--
-- PostgreSQL owns:
--   - validation of the claimed outbox lease
--   - canonical call / prospect / contact verification
--   - crash-safe already-persisted-send detection
--   - CURRENT SMS eligibility / DND / revocation re-check
--   - deterministic SEND vs NO-SEND decision
--
-- This function DOES NOT call Twilio.
-- This function DOES NOT complete/fail the outbox lease.
-- ============================================================================

create or replace function public.prepare_twilio_missed_call_recovery_sms_v1(
    p_outbox_event_id uuid,
    p_worker_id text
)
returns table (
    disposition text,
    next_action text,

    outbox_event_id uuid,
    correlation_id uuid,

    call_id uuid,
    prospect_id uuid,
    contact_point_id uuid,

    provider_call_id text,
    to_phone text,

    template_code text,
    reason_code text,

    existing_message_id uuid,
    review_outbox_event_id uuid
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_worker_id text;

    v_outbox public.outbox_events%rowtype;
    v_call public.calls%rowtype;

    v_contact public.contact_points%rowtype;

    v_payload_call_id uuid;
    v_payload_prospect_id uuid;
    v_payload_contact_point_id uuid;

    v_provider_call_id text;
    v_phone text;

    v_existing_message public.messages%rowtype;
    v_existing_message_count integer := 0;

    v_has_any_eligibility boolean := false;
    v_has_current_eligible boolean := false;
    v_has_current_review boolean := false;

    v_has_current_dnd boolean := false;
    v_has_current_revoked boolean := false;
    v_has_current_ineligible boolean := false;

    v_reason text;
    v_disposition text;
    v_next_action text;

    v_review_key text;
    v_review public.outbox_events%rowtype;
begin
    --------------------------------------------------------------------------
    -- 1. Invocation boundary.
    --------------------------------------------------------------------------

    if p_outbox_event_id is null then
        raise exception
            'outbox event ID is required'
            using errcode = '22023';
    end if;


    v_worker_id :=
        nullif(
            btrim(
                coalesce(
                    p_worker_id,
                    ''
                )
            ),
            ''
        );


    if v_worker_id is null then
        raise exception
            'worker ID is required'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 2. Resolve and lock claimed READY work.
    --------------------------------------------------------------------------

    select oe.*
    into v_outbox
    from public.outbox_events as oe
    where oe.outbox_event_id =
            p_outbox_event_id
    for update;


    if not found then
        raise exception
            'outbox event does not exist'
            using errcode = '22023';
    end if;


    if v_outbox.event_type <>
        'TWILIO_MISSED_CALL_RECOVERY_READY'
    then
        raise exception
            'outbox event is not TWILIO_MISSED_CALL_RECOVERY_READY'
            using errcode = '22023';
    end if;


    if v_outbox.status <> 'PROCESSING' then
        raise exception
            'outbox event is not currently processing'
            using errcode = '22000';
    end if;


    if (
        v_outbox.locked_at is null
        or v_outbox.locked_by is distinct from
            v_worker_id
    ) then
        raise exception
            'worker does not own the outbox event lease'
            using errcode = '22000';
    end if;


    if (
        v_outbox.aggregate_type <> 'CALL'
        or v_outbox.aggregate_id is null
    ) then
        raise exception
            'recovery outbox event has invalid aggregate context'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 3. Validate immutable payload references.
    --------------------------------------------------------------------------

    begin
        v_payload_call_id :=
            nullif(
                v_outbox.payload ->> 'call_id',
                ''
            )::uuid;

        v_payload_prospect_id :=
            nullif(
                v_outbox.payload ->> 'prospect_id',
                ''
            )::uuid;

        v_payload_contact_point_id :=
            nullif(
                v_outbox.payload ->> 'contact_point_id',
                ''
            )::uuid;

    exception
        when invalid_text_representation then
            raise exception
                'recovery outbox contains malformed UUID context'
                using errcode = '22000';
    end;


    v_provider_call_id :=
        nullif(
            btrim(
                coalesce(
                    v_outbox.payload ->> 'provider_call_id',
                    ''
                )
            ),
            ''
        );


    v_phone :=
        nullif(
            btrim(
                coalesce(
                    v_outbox.payload ->> 'normalized_phone',
                    ''
                )
            ),
            ''
        );


    if v_outbox.payload ->> 'provider' <>
        'TWILIO'
    then
        raise exception
            'recovery outbox provider is not TWILIO'
            using errcode = '22000';
    end if;


    if v_outbox.payload ->> 'decision' <>
        'RECOVERY_READY'
    then
        raise exception
            'recovery outbox does not contain a READY decision'
            using errcode = '22000';
    end if;


    if (
        v_payload_call_id is null
        or v_payload_call_id <>
            v_outbox.aggregate_id
    ) then
        raise exception
            'recovery outbox call identity is inconsistent'
            using errcode = '22000';
    end if;


    if (
        v_payload_prospect_id is null
        or v_payload_contact_point_id is null
        or v_provider_call_id is null
        or v_phone is null
    ) then
        raise exception
            'recovery outbox is missing required transport context'
            using errcode = '22000';
    end if;


    if v_phone !~
        '^\+[1-9][0-9]{7,14}$'
    then
        raise exception
            'recovery phone is not canonical E.164'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 4. Crash-safe replay after successful persistence.
    --
    -- Phase 6C.3 will persist source_outbox_event_id in structured_content.
    -- If that durable success already exists, transport must not run again.
    --------------------------------------------------------------------------

    select count(*)
    into v_existing_message_count
    from public.messages as m
    where m.provider = 'TWILIO'
      and m.channel = 'SMS'
      and m.direction = 'OUTBOUND'
      and m.structured_content ->>
            'source_outbox_event_id' =
            p_outbox_event_id::text;


    if v_existing_message_count > 1 then
        raise exception
            'multiple outbound messages exist for one recovery outbox event'
            using errcode = '22000';
    end if;


    if v_existing_message_count = 1 then
        select m.*
        into v_existing_message
        from public.messages as m
        where m.provider = 'TWILIO'
          and m.channel = 'SMS'
          and m.direction = 'OUTBOUND'
          and m.structured_content ->>
                'source_outbox_event_id' =
                p_outbox_event_id::text
        limit 1;


        return query
        select
            'ALREADY_PERSISTED'::text,
            'COMPLETE_OUTBOX'::text,

            v_outbox.outbox_event_id,
            v_outbox.correlation_id,

            v_outbox.aggregate_id,
            v_payload_prospect_id,
            v_payload_contact_point_id,

            v_provider_call_id,
            v_phone,

            null::text,
            'OUTBOUND_MESSAGE_ALREADY_PERSISTED'::text,

            v_existing_message.message_id,
            null::uuid;

        return;
    end if;


    --------------------------------------------------------------------------
    -- 5. Resolve current canonical call.
    --------------------------------------------------------------------------

    select c.*
    into v_call
    from public.calls as c
    where c.call_id =
            v_outbox.aggregate_id
    for update;


    if not found then
        raise exception
            'canonical recovery call does not exist'
            using errcode = '22023';
    end if;


    if (
        v_call.provider <> 'TWILIO'
        or v_call.provider_call_id <>
            v_provider_call_id
    ) then
        raise exception
            'recovery outbox conflicts with canonical Twilio call'
            using errcode = '22000';
    end if;


    if (
        v_call.call_type <> 'PHONE'
        or v_call.direction <> 'INBOUND'
    ) then
        raise exception
            'recovery call is not an inbound PHONE call'
            using errcode = '22000';
    end if;


    if v_call.prospect_id is distinct from
        v_payload_prospect_id
    then
        raise exception
            'recovery call prospect identity changed'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 6. The call must STILL qualify as missed.
    --
    -- A later authoritative provider event may have changed the canonical
    -- call after the READY event was created.
    --------------------------------------------------------------------------

    if v_call.disconnection_reason not in (
        'TWILIO_NO_ANSWER',
        'TWILIO_BUSY',
        'TWILIO_CANCELED',
        'TWILIO_FAILED'
    ) then
        v_disposition :=
            'BLOCKED';

        v_next_action :=
            'COMPLETE_OUTBOX';

        v_reason :=
            'CALL_NO_LONGER_MISSED';


        return query
        select
            v_disposition,
            v_next_action,

            v_outbox.outbox_event_id,
            v_outbox.correlation_id,

            v_call.call_id,
            v_payload_prospect_id,
            v_payload_contact_point_id,

            v_provider_call_id,
            v_phone,

            null::text,
            v_reason,

            null::uuid,
            null::uuid;

        return;
    end if;


    --------------------------------------------------------------------------
    -- 7. Prospect must remain an active canonical identity.
    --------------------------------------------------------------------------

    if not exists (
        select 1
        from public.prospects as p
        where p.prospect_id =
                v_payload_prospect_id
          and p.identity_status =
                'ACTIVE'
    ) then
        v_disposition :=
            'REVIEW_REQUIRED';

        v_next_action :=
            'COMPLETE_OUTBOX';

        v_reason :=
            'PROSPECT_NOT_ACTIVE';
    end if;


    --------------------------------------------------------------------------
    -- 8. Resolve exact current phone contact.
    --------------------------------------------------------------------------

    if v_disposition is null then
        select cp.*
        into v_contact
        from public.contact_points as cp
        where cp.contact_point_id =
                v_payload_contact_point_id
          and cp.prospect_id =
                v_payload_prospect_id
          and cp.contact_type =
                'PHONE'
        for update;


        if not found then
            raise exception
                'recovery contact point does not exist'
                using errcode = '22023';
        end if;


        if v_contact.normalized_value <>
            v_phone
        then
            raise exception
                'recovery phone conflicts with canonical contact point'
                using errcode = '22000';
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 9. CURRENT eligibility re-check.
    --
    -- Evaluate both:
    --   - prospect-scoped SMS / INBOUND_RESPONSE state
    --   - contact-scoped SMS / INBOUND_RESPONSE state
    --
    -- Precedence:
    --   BLOCK > REVIEW > ELIGIBLE
    --------------------------------------------------------------------------

    if v_disposition is null then
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
                    ce.eligibility_state =
                        'INELIGIBLE'
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
                    ce.eligibility_state =
                        'REVIEW_REQUIRED'
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
                    ce.eligibility_state =
                        'ELIGIBLE'
                    and ce.dnd is false
                    and ce.consent_basis <>
                        'REVOKED'
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
                v_payload_prospect_id
          and ce.channel =
                'SMS'
          and ce.purpose =
                'INBOUND_RESPONSE'
          and (
              ce.contact_point_id is null
              or ce.contact_point_id =
                    v_payload_contact_point_id
          );


        if v_has_current_dnd then
            v_disposition :=
                'BLOCKED';

            v_next_action :=
                'COMPLETE_OUTBOX';

            v_reason :=
                'DND';


        elsif v_has_current_revoked then
            v_disposition :=
                'BLOCKED';

            v_next_action :=
                'COMPLETE_OUTBOX';

            v_reason :=
                'CONSENT_REVOKED';


        elsif v_has_current_ineligible then
            v_disposition :=
                'BLOCKED';

            v_next_action :=
                'COMPLETE_OUTBOX';

            v_reason :=
                'SMS_INELIGIBLE';


        elsif v_has_current_review then
            v_disposition :=
                'REVIEW_REQUIRED';

            v_next_action :=
                'COMPLETE_OUTBOX';

            v_reason :=
                'SMS_ELIGIBILITY_REVIEW_REQUIRED';


        elsif v_has_current_eligible then
            v_disposition :=
                'PREPARED';

            v_next_action :=
                'SEND_SMS';

            v_reason :=
                'CURRENT_SMS_ELIGIBILITY';


        elsif v_has_any_eligibility then
            v_disposition :=
                'REVIEW_REQUIRED';

            v_next_action :=
                'COMPLETE_OUTBOX';

            v_reason :=
                'ELIGIBILITY_NOT_CURRENT';


        else
            v_disposition :=
                'REVIEW_REQUIRED';

            v_next_action :=
                'COMPLETE_OUTBOX';

            v_reason :=
                'ELIGIBILITY_MISSING_AT_SEND';
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 10. A newly discovered review condition must remain operator-visible.
    --------------------------------------------------------------------------

    if v_disposition =
        'REVIEW_REQUIRED'
    then
        v_review_key :=
            'TWILIO:CALL:' ||
            v_provider_call_id ||
            ':MISSED_RECOVERY_TRANSPORT_REVIEW_REQUIRED';


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
            v_review_key,
            'TWILIO_MISSED_CALL_RECOVERY_REVIEW_REQUIRED',
            'CALL',
            v_call.call_id,
            v_outbox.source_raw_provider_event_id,
            v_outbox.correlation_id,

            jsonb_build_object(
                'provider',
                'TWILIO',

                'stage',
                'PRE_SEND_ELIGIBILITY_RECHECK',

                'source_outbox_event_id',
                v_outbox.outbox_event_id,

                'call_id',
                v_call.call_id,

                'prospect_id',
                v_payload_prospect_id,

                'contact_point_id',
                v_payload_contact_point_id,

                'provider_call_id',
                v_provider_call_id,

                'normalized_phone',
                v_phone,

                'decision',
                'REVIEW_REQUIRED',

                'reason_code',
                v_reason
            )
        )
        on conflict on constraint
            outbox_events_event_key_unique
        do nothing
        returning *
        into v_review;


        if not found then
            select oe.*
            into v_review
            from public.outbox_events as oe
            where oe.event_key =
                    v_review_key;


            if not found then
                raise exception
                    'transport review event replay could not be resolved'
                    using errcode = 'P0001';
            end if;


            if (
                v_review.aggregate_id
                    is distinct from
                v_call.call_id
                or v_review.correlation_id
                    is distinct from
                v_outbox.correlation_id
            ) then
                raise exception
                    'transport review event conflicts with canonical recovery state'
                    using errcode = '22000';
            end if;
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 11. Return transport contract.
    --
    -- n8n / transport adapter may not supply arbitrary customer-facing body.
    -- SEND_SMS receives only a controlled template code.
    --------------------------------------------------------------------------

    return query
    select
        v_disposition,
        v_next_action,

        v_outbox.outbox_event_id,
        v_outbox.correlation_id,

        v_call.call_id,
        v_payload_prospect_id,
        v_payload_contact_point_id,

        v_provider_call_id,
        v_phone,

        case
            when v_disposition = 'PREPARED'
                then 'MISSED_CALL_RECOVERY_V1'
            else null::text
        end,

        v_reason,

        null::uuid,

        case
            when v_review.outbox_event_id is null
                then null::uuid
            else v_review.outbox_event_id
        end;
end;
$function$;


comment on function
public.prepare_twilio_missed_call_recovery_sms_v1(
    uuid,
    text
)
is
'Phase 6C.1 pre-send Twilio recovery SMS gate. Validates the claimed READY lease, detects already-persisted sends, verifies the call still qualifies, and re-checks current prospect/contact SMS eligibility immediately before transport. Returns a controlled template code and performs no provider call or outbox completion.';


revoke all
on function
public.prepare_twilio_missed_call_recovery_sms_v1(
    uuid,
    text
)
from public;


revoke all
on function
public.prepare_twilio_missed_call_recovery_sms_v1(
    uuid,
    text
)
from anon;


revoke all
on function
public.prepare_twilio_missed_call_recovery_sms_v1(
    uuid,
    text
)
from authenticated;


grant execute
on function
public.prepare_twilio_missed_call_recovery_sms_v1(
    uuid,
    text
)
to service_role;