-- ============================================================================
-- Phase 6C.3
-- Durable outbound SMS provider-attempt state.
--
-- PostgreSQL remains authoritative for:
--   - whether a provider send may begin;
--   - whether an earlier provider boundary is ambiguous;
--   - durable successful-message persistence;
--   - retryable / final / unknown transport outcomes.
--
-- n8n remains the asynchronous orchestrator.
--
-- IMPORTANT:
-- A previous SENDING attempt from an older outbox claim is treated as UNKNOWN.
-- It is never interpreted as permission to resend.
-- ============================================================================


-- ============================================================================
-- 1. OUTBOUND PROVIDER ATTEMPT LEDGER
-- ============================================================================

create table public.outbound_message_attempts (
    outbound_message_attempt_id uuid
        primary key
        default gen_random_uuid(),

    source_outbox_event_id uuid
        not null
        references public.outbox_events(outbox_event_id),

    outbox_attempt_number integer
        not null,

    correlation_id uuid
        not null,

    call_id uuid
        not null
        references public.calls(call_id),

    prospect_id uuid
        not null
        references public.prospects(prospect_id),

    contact_point_id uuid
        not null
        references public.contact_points(contact_point_id),

    provider text
        not null
        default 'TWILIO',

    worker_id text
        not null,

    to_phone text
        not null,

    template_code text
        not null,

    state text
        not null
        default 'SENDING',

    provider_message_id text,

    provider_status text,

    retryable boolean
        not null
        default false,

    error_code text,

    sanitized_message text,

    conversation_id uuid
        references public.conversations(conversation_id),

    message_id uuid
        references public.messages(message_id),

    failure_event_id uuid
        references public.failure_events(failure_event_id),

    review_outbox_event_id uuid
        references public.outbox_events(outbox_event_id),

    started_at timestamptz
        not null
        default now(),

    completed_at timestamptz,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),

    constraint outbound_message_attempts_attempt_number_check
        check (
            outbox_attempt_number >= 1
        ),

    constraint outbound_message_attempts_provider_check
        check (
            provider = 'TWILIO'
        ),

    constraint outbound_message_attempts_state_check
        check (
            state in (
                'SENDING',
                'PERSISTED',
                'REJECTED_RETRYABLE',
                'REJECTED_FINAL',
                'UNKNOWN'
            )
        ),

    constraint outbound_message_attempts_terminal_time_check
        check (
            state = 'SENDING'
            or completed_at is not null
        ),

    constraint outbound_message_attempts_persisted_shape_check
        check (
            state <> 'PERSISTED'
            or (
                provider_message_id is not null
                and conversation_id is not null
                and message_id is not null
            )
        ),

    constraint outbound_message_attempts_source_attempt_unique
        unique (
            source_outbox_event_id,
            outbox_attempt_number
        )
);


create index outbound_message_attempts_source_idx
    on public.outbound_message_attempts(
        source_outbox_event_id,
        outbox_attempt_number desc
    );


create index outbound_message_attempts_state_idx
    on public.outbound_message_attempts(
        state,
        updated_at desc
    );


create unique index outbound_message_attempts_provider_message_unique_idx
    on public.outbound_message_attempts(
        provider,
        provider_message_id
    )
    where provider_message_id is not null;


-- One outbound Twilio message may be durably associated with a source outbox
-- event only once. Phase 6C.1 already checks this marker before allowing send.
create unique index messages_twilio_source_outbox_unique_idx
    on public.messages(
        (
            structured_content
                ->> 'source_outbox_event_id'
        )
    )
    where provider = 'TWILIO'
      and channel = 'SMS'
      and direction = 'OUTBOUND'
      and structured_content
            ? 'source_outbox_event_id';


create trigger outbound_message_attempts_set_updated_at
before update
on public.outbound_message_attempts
for each row
execute function public.set_updated_at();


alter table public.outbound_message_attempts
    enable row level security;


revoke all
on table public.outbound_message_attempts
from anon, authenticated;


grant
    select,
    insert,
    update
on table public.outbound_message_attempts
to service_role;



-- ============================================================================
-- 2. BEGIN / RESERVE PROVIDER SEND
--
-- This function calls the Phase 6C.1 pre-send gate in the SAME database
-- transaction. A durable SENDING row is created only if that gate still
-- returns PREPARED / SEND_SMS.
--
-- It never contacts Twilio.
-- ============================================================================

create or replace function public.begin_twilio_recovery_sms_attempt_v1(
    p_outbox_event_id uuid,
    p_worker_id text
)
returns table (
    disposition text,
    next_action text,

    outbound_message_attempt_id uuid,

    outbox_event_id uuid,
    outbox_attempt_number integer,

    correlation_id uuid,

    call_id uuid,
    prospect_id uuid,
    contact_point_id uuid,

    to_phone text,
    template_code text,

    provider_message_id text,
    provider_status text,

    reason_code text,

    message_id uuid,
    review_outbox_event_id uuid
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_outbox public.outbox_events%rowtype;

    v_prepare record;

    v_existing
        public.outbound_message_attempts%rowtype;

    v_attempt
        public.outbound_message_attempts%rowtype;

    v_failure_event_id uuid;
    v_review_outbox_event_id uuid;

    v_review_key text;
begin
    if p_outbox_event_id is null then
        raise exception
            using
                errcode = '22000',
                message =
                    'p_outbox_event_id is required';
    end if;


    if coalesce(
        btrim(p_worker_id),
        ''
    ) = '' then
        raise exception
            using
                errcode = '22000',
                message =
                    'p_worker_id is required';
    end if;


    select oe.*
    into v_outbox
    from public.outbox_events as oe
    where oe.outbox_event_id =
        p_outbox_event_id
    for update;


    if not found then
        raise exception
            using
                errcode = '22000',
                message =
                    'outbox event not found';
    end if;


    if v_outbox.event_type
        is distinct from
        'TWILIO_MISSED_CALL_RECOVERY_READY'
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'outbox event is not a Twilio missed-call recovery READY event';
    end if;


    if v_outbox.status
        is distinct from
        'PROCESSING'
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'outbox event is not PROCESSING';
    end if;


    if v_outbox.locked_at is null
       or v_outbox.locked_by
            is distinct from
            p_worker_id
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'worker does not own the outbox lease';
    end if;


    if v_outbox.attempts < 1 then
        raise exception
            using
                errcode = '22000',
                message =
                    'claimed outbox event has invalid attempt number';
    end if;


    -- ------------------------------------------------------------------------
    -- Run the authoritative 6C.1 pre-send policy gate immediately before
    -- reserving the provider boundary.
    -- ------------------------------------------------------------------------

    select *
    into v_prepare
    from public.prepare_twilio_missed_call_recovery_sms_v1(
        p_outbox_event_id,
        p_worker_id
    );


    if v_prepare.next_action
        is distinct from
        'SEND_SMS'
    then
        return query
        select
            v_prepare.disposition::text,
            v_prepare.next_action::text,

            null::uuid,

            p_outbox_event_id,
            v_outbox.attempts,

            v_outbox.correlation_id,

            v_prepare.call_id,
            v_prepare.prospect_id,
            v_prepare.contact_point_id,

            v_prepare.to_phone,
            v_prepare.template_code,

            null::text,
            null::text,

            v_prepare.reason_code,

            v_prepare.existing_message_id,
            v_prepare.review_outbox_event_id;

        return;
    end if;


    if v_prepare.disposition
        is distinct from
        'PREPARED'
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'SEND_SMS requires PREPARED disposition';
    end if;


    if v_prepare.template_code
        is distinct from
        'MISSED_CALL_RECOVERY_V1'
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'unsupported recovery SMS template';
    end if;


    -- ------------------------------------------------------------------------
    -- Inspect the latest provider-boundary attempt for this source event.
    -- ------------------------------------------------------------------------

    select oma.*
    into v_existing
    from public.outbound_message_attempts as oma
    where oma.source_outbox_event_id =
        p_outbox_event_id
    order by
        oma.outbox_attempt_number desc
    limit 1
    for update;


    if found then

        if v_existing.outbox_attempt_number
            > v_outbox.attempts
        then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'provider attempt number is ahead of outbox claim state';
        end if;


        -- --------------------------------------------------------------------
        -- Same outbox claim replay.
        --
        -- SENDING means this claim has already reserved the network boundary.
        -- Never issue a second provider request.
        -- --------------------------------------------------------------------

        if v_existing.outbox_attempt_number
            = v_outbox.attempts
        then

            if v_existing.state = 'SENDING' then
                return query
                select
                    'IN_PROGRESS'::text,
                    'DO_NOT_SEND'::text,

                    v_existing.outbound_message_attempt_id,

                    p_outbox_event_id,
                    v_existing.outbox_attempt_number,

                    v_existing.correlation_id,

                    v_existing.call_id,
                    v_existing.prospect_id,
                    v_existing.contact_point_id,

                    v_existing.to_phone,
                    v_existing.template_code,

                    v_existing.provider_message_id,
                    v_existing.provider_status,

                    'ATTEMPT_ALREADY_RESERVED'::text,

                    v_existing.message_id,
                    v_existing.review_outbox_event_id;

                return;
            end if;


            if v_existing.state = 'PERSISTED' then
                return query
                select
                    'ALREADY_PERSISTED'::text,
                    'COMPLETE_OUTBOX'::text,

                    v_existing.outbound_message_attempt_id,

                    p_outbox_event_id,
                    v_existing.outbox_attempt_number,

                    v_existing.correlation_id,

                    v_existing.call_id,
                    v_existing.prospect_id,
                    v_existing.contact_point_id,

                    v_existing.to_phone,
                    v_existing.template_code,

                    v_existing.provider_message_id,
                    v_existing.provider_status,

                    'OUTBOUND_MESSAGE_ALREADY_PERSISTED'::text,

                    v_existing.message_id,
                    v_existing.review_outbox_event_id;

                return;
            end if;


            if v_existing.state =
                'REJECTED_RETRYABLE'
            then
                return query
                select
                    'RETRYABLE_REJECTION_RECORDED'::text,
                    'FAIL_OUTBOX'::text,

                    v_existing.outbound_message_attempt_id,

                    p_outbox_event_id,
                    v_existing.outbox_attempt_number,

                    v_existing.correlation_id,

                    v_existing.call_id,
                    v_existing.prospect_id,
                    v_existing.contact_point_id,

                    v_existing.to_phone,
                    v_existing.template_code,

                    v_existing.provider_message_id,
                    v_existing.provider_status,

                    'RETRYABLE_PROVIDER_REJECTION'::text,

                    v_existing.message_id,
                    v_existing.review_outbox_event_id;

                return;
            end if;


            if v_existing.state =
                'REJECTED_FINAL'
            then
                return query
                select
                    'REJECTED_FINAL'::text,
                    'COMPLETE_OUTBOX'::text,

                    v_existing.outbound_message_attempt_id,

                    p_outbox_event_id,
                    v_existing.outbox_attempt_number,

                    v_existing.correlation_id,

                    v_existing.call_id,
                    v_existing.prospect_id,
                    v_existing.contact_point_id,

                    v_existing.to_phone,
                    v_existing.template_code,

                    v_existing.provider_message_id,
                    v_existing.provider_status,

                    'NON_RETRYABLE_PROVIDER_REJECTION'::text,

                    v_existing.message_id,
                    v_existing.review_outbox_event_id;

                return;
            end if;


            if v_existing.state = 'UNKNOWN' then
                return query
                select
                    'REVIEW_REQUIRED'::text,
                    'COMPLETE_OUTBOX'::text,

                    v_existing.outbound_message_attempt_id,

                    p_outbox_event_id,
                    v_existing.outbox_attempt_number,

                    v_existing.correlation_id,

                    v_existing.call_id,
                    v_existing.prospect_id,
                    v_existing.contact_point_id,

                    v_existing.to_phone,
                    v_existing.template_code,

                    v_existing.provider_message_id,
                    v_existing.provider_status,

                    'PROVIDER_OUTCOME_UNKNOWN'::text,

                    v_existing.message_id,
                    v_existing.review_outbox_event_id;

                return;
            end if;


            raise exception
                using
                    errcode = '22000',
                    message =
                        'unsupported existing provider-attempt state';
        end if;


        -- --------------------------------------------------------------------
        -- Older provider attempt observed after a later outbox reclaim.
        --
        -- An older SENDING row is the dangerous crash window:
        --
        --   provider request may have happened
        --   local finalization did not happen
        --
        -- It becomes UNKNOWN and absolutely does not authorize another send.
        -- --------------------------------------------------------------------

        if v_existing.state = 'SENDING' then

            update public.outbound_message_attempts
            set
                state = 'UNKNOWN',
                retryable = false,
                error_code =
                    coalesce(
                        error_code,
                        'AMBIGUOUS_PREVIOUS_SEND'
                    ),
                sanitized_message =
                    coalesce(
                        sanitized_message,
                        'A prior Twilio SMS provider request may have crossed the network boundary. Automatic resend is unsafe.'
                    ),
                completed_at =
                    coalesce(
                        completed_at,
                        now()
                    )
            where public.outbound_message_attempts.outbound_message_attempt_id =
                v_existing.outbound_message_attempt_id
            returning *
            into v_existing;


            if v_existing.failure_event_id
                is null
            then
                insert into public.failure_events as inserted_failure (
                    correlation_id,
                    provider,
                    stage,
                    error_class,
                    severity,
                    retryable,
                    error_code,
                    sanitized_message,
                    entity_type,
                    entity_id,
                    attempt_count,
                    resolution_status
                )
                values (
                    v_existing.correlation_id,
                    'TWILIO',
                    'TWILIO_RECOVERY_SMS_SEND',
                    'SMS_PROVIDER',
                    'ERROR',
                    false,
                    'AMBIGUOUS_PREVIOUS_SEND',
                    'A prior Twilio SMS provider request may have crossed the network boundary. Automatic resend is unsafe.',
                    'OUTBOUND_MESSAGE_ATTEMPT',
                    v_existing.outbound_message_attempt_id,
                    v_existing.outbox_attempt_number,
                    'OPEN'
                )
                returning failure_event_id
                into v_failure_event_id;


                update public.outbound_message_attempts
                set failure_event_id =
                    v_failure_event_id
                where public.outbound_message_attempts.outbound_message_attempt_id =
                    v_existing.outbound_message_attempt_id;
            else
                v_failure_event_id :=
                    v_existing.failure_event_id;
            end if;


            v_review_key :=
                'TWILIO:OUTBOX:'
                || p_outbox_event_id::text
                || ':SMS_TRANSPORT_REVIEW_REQUIRED';


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
                v_existing.call_id,
                v_outbox.source_raw_provider_event_id,
                v_existing.correlation_id,
                jsonb_build_object(
                    'stage',
                        'SMS_TRANSPORT_UNKNOWN',

                    'source_outbox_event_id',
                        p_outbox_event_id,

                    'outbound_message_attempt_id',
                        v_existing.outbound_message_attempt_id,

                    'outbox_attempt_number',
                        v_existing.outbox_attempt_number,

                    'call_id',
                        v_existing.call_id,

                    'prospect_id',
                        v_existing.prospect_id,

                    'contact_point_id',
                        v_existing.contact_point_id,

                    'provider',
                        'TWILIO',

                    'to_phone',
                        v_existing.to_phone,

                    'template_code',
                        v_existing.template_code,

                    'decision',
                        'REVIEW_REQUIRED',

                    'reason_code',
                        'PROVIDER_OUTCOME_UNKNOWN'
                )
            )
            on conflict (
                event_key
            )
            do nothing;


            select oe.outbox_event_id
            into v_review_outbox_event_id
            from public.outbox_events as oe
            where oe.event_key =
                v_review_key;


            update public.outbound_message_attempts
            set review_outbox_event_id =
                v_review_outbox_event_id
            where public.outbound_message_attempts.outbound_message_attempt_id =
                v_existing.outbound_message_attempt_id;


            return query
            select
                'REVIEW_REQUIRED'::text,
                'COMPLETE_OUTBOX'::text,

                v_existing.outbound_message_attempt_id,

                p_outbox_event_id,
                v_existing.outbox_attempt_number,

                v_existing.correlation_id,

                v_existing.call_id,
                v_existing.prospect_id,
                v_existing.contact_point_id,

                v_existing.to_phone,
                v_existing.template_code,

                v_existing.provider_message_id,
                v_existing.provider_status,

                'PROVIDER_OUTCOME_UNKNOWN'::text,

                v_existing.message_id,
                v_review_outbox_event_id;

            return;
        end if;


        if v_existing.state = 'PERSISTED' then
            return query
            select
                'ALREADY_PERSISTED'::text,
                'COMPLETE_OUTBOX'::text,

                v_existing.outbound_message_attempt_id,

                p_outbox_event_id,
                v_existing.outbox_attempt_number,

                v_existing.correlation_id,

                v_existing.call_id,
                v_existing.prospect_id,
                v_existing.contact_point_id,

                v_existing.to_phone,
                v_existing.template_code,

                v_existing.provider_message_id,
                v_existing.provider_status,

                'OUTBOUND_MESSAGE_ALREADY_PERSISTED'::text,

                v_existing.message_id,
                v_existing.review_outbox_event_id;

            return;
        end if;


        if v_existing.state = 'UNKNOWN' then
            return query
            select
                'REVIEW_REQUIRED'::text,
                'COMPLETE_OUTBOX'::text,

                v_existing.outbound_message_attempt_id,

                p_outbox_event_id,
                v_existing.outbox_attempt_number,

                v_existing.correlation_id,

                v_existing.call_id,
                v_existing.prospect_id,
                v_existing.contact_point_id,

                v_existing.to_phone,
                v_existing.template_code,

                v_existing.provider_message_id,
                v_existing.provider_status,

                'PROVIDER_OUTCOME_UNKNOWN'::text,

                v_existing.message_id,
                v_existing.review_outbox_event_id;

            return;
        end if;


        if v_existing.state =
            'REJECTED_FINAL'
        then
            return query
            select
                'REJECTED_FINAL'::text,
                'COMPLETE_OUTBOX'::text,

                v_existing.outbound_message_attempt_id,

                p_outbox_event_id,
                v_existing.outbox_attempt_number,

                v_existing.correlation_id,

                v_existing.call_id,
                v_existing.prospect_id,
                v_existing.contact_point_id,

                v_existing.to_phone,
                v_existing.template_code,

                v_existing.provider_message_id,
                v_existing.provider_status,

                'NON_RETRYABLE_PROVIDER_REJECTION'::text,

                v_existing.message_id,
                v_existing.review_outbox_event_id;

            return;
        end if;


        -- Only an explicitly retryable rejection from an OLDER outbox claim
        -- permits the newly claimed attempt to cross the provider boundary.
        if v_existing.state
            is distinct from
            'REJECTED_RETRYABLE'
        then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'previous provider attempt does not permit automatic retry';
        end if;
    end if;


    -- ------------------------------------------------------------------------
    -- Reserve this exact claimed outbox attempt before any provider call.
    -- ------------------------------------------------------------------------

    insert into public.outbound_message_attempts (
        source_outbox_event_id,
        outbox_attempt_number,
        correlation_id,
        call_id,
        prospect_id,
        contact_point_id,
        provider,
        worker_id,
        to_phone,
        template_code,
        state,
        retryable
    )
    values (
        p_outbox_event_id,
        v_outbox.attempts,
        v_outbox.correlation_id,
        v_prepare.call_id,
        v_prepare.prospect_id,
        v_prepare.contact_point_id,
        'TWILIO',
        p_worker_id,
        v_prepare.to_phone,
        v_prepare.template_code,
        'SENDING',
        false
    )
    returning *
    into v_attempt;


    return query
    select
        'RESERVED'::text,
        'SEND_SMS'::text,

        v_attempt.outbound_message_attempt_id,

        p_outbox_event_id,
        v_attempt.outbox_attempt_number,

        v_attempt.correlation_id,

        v_attempt.call_id,
        v_attempt.prospect_id,
        v_attempt.contact_point_id,

        v_attempt.to_phone,
        v_attempt.template_code,

        null::text,
        null::text,

        'PROVIDER_ATTEMPT_RESERVED'::text,

        null::uuid,
        null::uuid;
end;
$function$;


revoke all
on function public.begin_twilio_recovery_sms_attempt_v1(
    uuid,
    text
)
from public, anon, authenticated;


grant execute
on function public.begin_twilio_recovery_sms_attempt_v1(
    uuid,
    text
)
to service_role;



-- ============================================================================
-- 3. FINALIZE PROVIDER OUTCOME
--
-- ACCEPTED:
--   conversation + outbound message + attempt persistence are atomic.
--
-- REJECTED retryable:
--   durable failure_event, caller should fail/requeue generic outbox.
--
-- REJECTED final:
--   durable failure_event + human-review outbox, no resend.
--
-- UNKNOWN:
--   durable failure_event + human-review outbox, no automatic resend.
-- ============================================================================

create or replace function public.finalize_twilio_recovery_sms_attempt_v1(
    p_outbound_message_attempt_id uuid,
    p_worker_id text,

    p_outcome text,

    p_provider_message_id text,
    p_provider_status text,

    p_retryable boolean,

    p_error_code text,
    p_sanitized_message text,

    p_message_body text
)
returns table (
    disposition text,
    next_action text,

    attempt_state text,

    outbound_message_attempt_id uuid,
    source_outbox_event_id uuid,
    outbox_attempt_number integer,

    provider_message_id text,

    conversation_id uuid,
    message_id uuid,

    failure_event_id uuid,
    review_outbox_event_id uuid,

    retry_after_seconds integer,

    reason_code text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_attempt_snapshot
        public.outbound_message_attempts%rowtype;

    v_attempt
        public.outbound_message_attempts%rowtype;

    v_outbox
        public.outbox_events%rowtype;

    v_conversation
        public.conversations%rowtype;

    v_existing_message
        public.messages%rowtype;

    v_message_id uuid;
    v_failure_event_id uuid;
    v_review_outbox_event_id uuid;

    v_external_conversation_id text;
    v_review_key text;

    v_outcome text;
begin
    if p_outbound_message_attempt_id
        is null
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'p_outbound_message_attempt_id is required';
    end if;


    if coalesce(
        btrim(p_worker_id),
        ''
    ) = '' then
        raise exception
            using
                errcode = '22000',
                message =
                    'p_worker_id is required';
    end if;


    v_outcome :=
        upper(
            coalesce(
                btrim(p_outcome),
                ''
            )
        );


    if v_outcome not in (
        'ACCEPTED',
        'REJECTED',
        'UNKNOWN'
    ) then
        raise exception
            using
                errcode = '22000',
                message =
                    'unsupported Twilio SMS transport outcome';
    end if;


    -- ------------------------------------------------------------------------
    -- First inspect without taking the provider-attempt lock.
    --
    -- Terminal rows are replay-safe and no longer require a live outbox lease.
    -- ------------------------------------------------------------------------

    select oma.*
    into v_attempt_snapshot
    from public.outbound_message_attempts as oma
    where oma.outbound_message_attempt_id =
        p_outbound_message_attempt_id;


    if not found then
        raise exception
            using
                errcode = '22000',
                message =
                    'outbound message attempt not found';
    end if;


    if v_attempt_snapshot.state =
        'PERSISTED'
    then
        return query
        select
            'ALREADY_PERSISTED'::text,
            'COMPLETE_OUTBOX'::text,

            v_attempt_snapshot.state,

            v_attempt_snapshot.outbound_message_attempt_id,
            v_attempt_snapshot.source_outbox_event_id,
            v_attempt_snapshot.outbox_attempt_number,

            v_attempt_snapshot.provider_message_id,

            v_attempt_snapshot.conversation_id,
            v_attempt_snapshot.message_id,

            v_attempt_snapshot.failure_event_id,
            v_attempt_snapshot.review_outbox_event_id,

            null::integer,

            'OUTBOUND_MESSAGE_ALREADY_PERSISTED'::text;

        return;
    end if;


    if v_attempt_snapshot.state =
        'REJECTED_RETRYABLE'
    then
        return query
        select
            'RETRYABLE_REJECTION_RECORDED'::text,
            'FAIL_OUTBOX'::text,

            v_attempt_snapshot.state,

            v_attempt_snapshot.outbound_message_attempt_id,
            v_attempt_snapshot.source_outbox_event_id,
            v_attempt_snapshot.outbox_attempt_number,

            v_attempt_snapshot.provider_message_id,

            v_attempt_snapshot.conversation_id,
            v_attempt_snapshot.message_id,

            v_attempt_snapshot.failure_event_id,
            v_attempt_snapshot.review_outbox_event_id,

            60,

            'RETRYABLE_PROVIDER_REJECTION'::text;

        return;
    end if;


    if v_attempt_snapshot.state =
        'REJECTED_FINAL'
    then
        return query
        select
            'REJECTED_FINAL'::text,
            'COMPLETE_OUTBOX'::text,

            v_attempt_snapshot.state,

            v_attempt_snapshot.outbound_message_attempt_id,
            v_attempt_snapshot.source_outbox_event_id,
            v_attempt_snapshot.outbox_attempt_number,

            v_attempt_snapshot.provider_message_id,

            v_attempt_snapshot.conversation_id,
            v_attempt_snapshot.message_id,

            v_attempt_snapshot.failure_event_id,
            v_attempt_snapshot.review_outbox_event_id,

            null::integer,

            'NON_RETRYABLE_PROVIDER_REJECTION'::text;

        return;
    end if;


    if v_attempt_snapshot.state =
        'UNKNOWN'
    then
        return query
        select
            'REVIEW_REQUIRED'::text,
            'COMPLETE_OUTBOX'::text,

            v_attempt_snapshot.state,

            v_attempt_snapshot.outbound_message_attempt_id,
            v_attempt_snapshot.source_outbox_event_id,
            v_attempt_snapshot.outbox_attempt_number,

            v_attempt_snapshot.provider_message_id,

            v_attempt_snapshot.conversation_id,
            v_attempt_snapshot.message_id,

            v_attempt_snapshot.failure_event_id,
            v_attempt_snapshot.review_outbox_event_id,

            null::integer,

            'PROVIDER_OUTCOME_UNKNOWN'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Non-terminal finalization requires the live outbox lease.
    -- Lock order matches begin(): outbox first, attempt second.
    -- ------------------------------------------------------------------------

    select oe.*
    into v_outbox
    from public.outbox_events oe
    where oe.outbox_event_id =
        v_attempt_snapshot.source_outbox_event_id
    for update;


    if not found then
        raise exception
            using
                errcode = '22000',
                message =
                    'source outbox event not found';
    end if;


    if v_outbox.status
        is distinct from
        'PROCESSING'
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'source outbox event is not PROCESSING';
    end if;


    if v_outbox.locked_at is null
       or v_outbox.locked_by
            is distinct from
            p_worker_id
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'worker does not own the source outbox lease';
    end if;


    select oma.*
    into v_attempt
    from public.outbound_message_attempts as oma
    where oma.outbound_message_attempt_id =
        p_outbound_message_attempt_id
    for update;


    if not found then
        raise exception
            using
                errcode = '22000',
                message =
                    'outbound message attempt disappeared';
    end if;


    -- The row may have become terminal while we waited for the lock.
    if v_attempt.state <> 'SENDING' then

        if v_attempt.state = 'PERSISTED' then
            return query
            select
                'ALREADY_PERSISTED'::text,
                'COMPLETE_OUTBOX'::text,

                v_attempt.state,

                v_attempt.outbound_message_attempt_id,
                v_attempt.source_outbox_event_id,
                v_attempt.outbox_attempt_number,

                v_attempt.provider_message_id,

                v_attempt.conversation_id,
                v_attempt.message_id,

                v_attempt.failure_event_id,
                v_attempt.review_outbox_event_id,

                null::integer,

                'OUTBOUND_MESSAGE_ALREADY_PERSISTED'::text;

            return;
        end if;


        if v_attempt.state =
            'REJECTED_RETRYABLE'
        then
            return query
            select
                'RETRYABLE_REJECTION_RECORDED'::text,
                'FAIL_OUTBOX'::text,

                v_attempt.state,

                v_attempt.outbound_message_attempt_id,
                v_attempt.source_outbox_event_id,
                v_attempt.outbox_attempt_number,

                v_attempt.provider_message_id,

                v_attempt.conversation_id,
                v_attempt.message_id,

                v_attempt.failure_event_id,
                v_attempt.review_outbox_event_id,

                60,

                'RETRYABLE_PROVIDER_REJECTION'::text;

            return;
        end if;


        if v_attempt.state =
            'REJECTED_FINAL'
        then
            return query
            select
                'REJECTED_FINAL'::text,
                'COMPLETE_OUTBOX'::text,

                v_attempt.state,

                v_attempt.outbound_message_attempt_id,
                v_attempt.source_outbox_event_id,
                v_attempt.outbox_attempt_number,

                v_attempt.provider_message_id,

                v_attempt.conversation_id,
                v_attempt.message_id,

                v_attempt.failure_event_id,
                v_attempt.review_outbox_event_id,

                null::integer,

                'NON_RETRYABLE_PROVIDER_REJECTION'::text;

            return;
        end if;


        if v_attempt.state = 'UNKNOWN' then
            return query
            select
                'REVIEW_REQUIRED'::text,
                'COMPLETE_OUTBOX'::text,

                v_attempt.state,

                v_attempt.outbound_message_attempt_id,
                v_attempt.source_outbox_event_id,
                v_attempt.outbox_attempt_number,

                v_attempt.provider_message_id,

                v_attempt.conversation_id,
                v_attempt.message_id,

                v_attempt.failure_event_id,
                v_attempt.review_outbox_event_id,

                null::integer,

                'PROVIDER_OUTCOME_UNKNOWN'::text;

            return;
        end if;


        raise exception
            using
                errcode = '22000',
                message =
                    'unsupported provider-attempt state';
    end if;


    if v_attempt.worker_id
        is distinct from
        p_worker_id
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'worker does not own the provider attempt';
    end if;


    if v_attempt.outbox_attempt_number
        is distinct from
        v_outbox.attempts
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'provider attempt does not belong to current outbox claim';
    end if;


    -- ========================================================================
    -- ACCEPTED
    -- ========================================================================

    if v_outcome = 'ACCEPTED' then

        if p_retryable then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'ACCEPTED outcome cannot be retryable';
        end if;


        if coalesce(
            btrim(p_provider_message_id),
            ''
        ) !~ '^SM[0-9A-Fa-f]{32}$'
        then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'ACCEPTED outcome requires a valid Twilio Message SID';
        end if;


        if coalesce(
            btrim(p_provider_status),
            ''
        ) = '' then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'ACCEPTED outcome requires provider status';
        end if;


        if coalesce(
            btrim(p_message_body),
            ''
        ) = '' then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'ACCEPTED outcome requires message body';
        end if;


        if length(p_message_body) > 1600 then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'outbound SMS body exceeds supported safety limit';
        end if;


        v_external_conversation_id :=
            'MISSED_RECOVERY:'
            || v_attempt.call_id::text;


        insert into public.conversations (
            prospect_id,
            call_id,
            channel,
            provider,
            external_conversation_id,
            state
        )
        values (
            v_attempt.prospect_id,
            v_attempt.call_id,
            'SMS',
            'TWILIO',
            v_external_conversation_id,
            'ACTIVE'
        )
        on conflict (
            provider,
            external_conversation_id
        )
        where external_conversation_id
            is not null
        do nothing;


        select *
        into v_conversation
        from public.conversations
        where provider = 'TWILIO'
          and external_conversation_id =
                v_external_conversation_id
        for update;


        if not found then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'failed to resolve outbound SMS conversation';
        end if;


        if v_conversation.channel
            is distinct from
            'SMS'
           or v_conversation.prospect_id
                is distinct from
                v_attempt.prospect_id
           or v_conversation.call_id
                is distinct from
                v_attempt.call_id
        then
            raise exception
                using
                    errcode = '22000',
                    message =
                        'existing SMS conversation conflicts with provider attempt';
        end if;


        select m.*
        into v_existing_message
        from public.messages m
        where m.provider = 'TWILIO'
          and m.channel = 'SMS'
          and m.direction = 'OUTBOUND'
          and m.structured_content
                ->> 'source_outbox_event_id'
                =
                v_attempt.source_outbox_event_id::text
        limit 1
        for update;


        if found then

            if v_existing_message.provider_message_id
                is distinct from
                p_provider_message_id
            then
                raise exception
                    using
                        errcode = '22000',
                        message =
                            'source outbox event already has a different provider Message SID';
            end if;


            v_message_id :=
                v_existing_message.message_id;

        else

            if exists (
                select 1
                from public.messages m
                where m.provider = 'TWILIO'
                  and m.provider_message_id =
                        p_provider_message_id
                  and (
                        m.structured_content
                            ->> 'source_outbox_event_id'
                      )
                      is distinct from
                      v_attempt.source_outbox_event_id::text
            ) then
                raise exception
                    using
                        errcode = '22000',
                        message =
                            'Twilio Message SID already belongs to another source event';
            end if;


            insert into public.messages as inserted_message (
                conversation_id,
                prospect_id,
                provider,
                provider_message_id,
                channel,
                direction,
                role,
                body,
                structured_content,
                occurred_at
            )
            values (
                v_conversation.conversation_id,
                v_attempt.prospect_id,
                'TWILIO',
                p_provider_message_id,
                'SMS',
                'OUTBOUND',
                'SYSTEM',
                p_message_body,
                jsonb_build_object(
                    'source_outbox_event_id',
                        v_attempt.source_outbox_event_id,

                    'outbound_message_attempt_id',
                        v_attempt.outbound_message_attempt_id,

                    'outbox_attempt_number',
                        v_attempt.outbox_attempt_number,

                    'template_code',
                        v_attempt.template_code,

                    'provider_status',
                        p_provider_status
                ),
                now()
            )
            returning inserted_message.message_id
            into v_message_id;
        end if;


        update public.outbound_message_attempts
        set
            state = 'PERSISTED',

            provider_message_id =
                p_provider_message_id,

            provider_status =
                p_provider_status,

            retryable = false,

            error_code = null,
            sanitized_message = null,

            conversation_id =
                v_conversation.conversation_id,

            message_id =
                v_message_id,

            completed_at =
                now()
        where public.outbound_message_attempts.outbound_message_attempt_id =
            v_attempt.outbound_message_attempt_id
        returning *
        into v_attempt;


        return query
        select
            'PERSISTED'::text,
            'COMPLETE_OUTBOX'::text,

            v_attempt.state,

            v_attempt.outbound_message_attempt_id,
            v_attempt.source_outbox_event_id,
            v_attempt.outbox_attempt_number,

            v_attempt.provider_message_id,

            v_attempt.conversation_id,
            v_attempt.message_id,

            v_attempt.failure_event_id,
            v_attempt.review_outbox_event_id,

            null::integer,

            'TWILIO_SMS_ACCEPTED_AND_PERSISTED'::text;

        return;
    end if;


    -- ========================================================================
    -- REJECTED / UNKNOWN
    -- ========================================================================

    if coalesce(
        btrim(p_sanitized_message),
        ''
    ) = '' then
        raise exception
            using
                errcode = '22000',
                message =
                    'failed transport outcome requires sanitized message';
    end if;


    if v_outcome = 'UNKNOWN'
       and p_retryable
    then
        raise exception
            using
                errcode = '22000',
                message =
                    'UNKNOWN provider outcome cannot be automatically retryable';
    end if;


    insert into public.failure_events as inserted_failure (
        correlation_id,
        provider,
        stage,
        error_class,
        severity,
        retryable,
        error_code,
        sanitized_message,
        entity_type,
        entity_id,
        attempt_count,
        resolution_status
    )
    values (
        v_attempt.correlation_id,
        'TWILIO',
        'TWILIO_RECOVERY_SMS_SEND',
        'SMS_PROVIDER',
        'ERROR',
        (
            v_outcome = 'REJECTED'
            and p_retryable
        ),
        nullif(
            btrim(
                coalesce(
                    p_error_code,
                    ''
                )
            ),
            ''
        ),
        p_sanitized_message,
        'OUTBOUND_MESSAGE_ATTEMPT',
        v_attempt.outbound_message_attempt_id,
        v_attempt.outbox_attempt_number,
        case
            when v_outcome = 'REJECTED'
                 and p_retryable
                then 'RETRY_SCHEDULED'
            else 'OPEN'
        end
    )
    returning inserted_failure.failure_event_id
    into v_failure_event_id;


    if v_outcome = 'REJECTED'
       and p_retryable
    then

        update public.outbound_message_attempts
        set
            state =
                'REJECTED_RETRYABLE',

            provider_status =
                nullif(
                    btrim(
                        coalesce(
                            p_provider_status,
                            ''
                        )
                    ),
                    ''
                ),

            retryable =
                true,

            error_code =
                nullif(
                    btrim(
                        coalesce(
                            p_error_code,
                            ''
                        )
                    ),
                    ''
                ),

            sanitized_message =
                p_sanitized_message,

            failure_event_id =
                v_failure_event_id,

            completed_at =
                now()
        where public.outbound_message_attempts.outbound_message_attempt_id =
            v_attempt.outbound_message_attempt_id
        returning *
        into v_attempt;


        return query
        select
            'RETRYABLE_REJECTION_RECORDED'::text,
            'FAIL_OUTBOX'::text,

            v_attempt.state,

            v_attempt.outbound_message_attempt_id,
            v_attempt.source_outbox_event_id,
            v_attempt.outbox_attempt_number,

            v_attempt.provider_message_id,

            v_attempt.conversation_id,
            v_attempt.message_id,

            v_attempt.failure_event_id,
            v_attempt.review_outbox_event_id,

            60,

            'RETRYABLE_PROVIDER_REJECTION'::text;

        return;
    end if;


    if v_outcome = 'UNKNOWN' then

        update public.outbound_message_attempts
        set
            state =
                'UNKNOWN',

            provider_status =
                nullif(
                    btrim(
                        coalesce(
                            p_provider_status,
                            ''
                        )
                    ),
                    ''
                ),

            retryable =
                false,

            error_code =
                nullif(
                    btrim(
                        coalesce(
                            p_error_code,
                            ''
                        )
                    ),
                    ''
                ),

            sanitized_message =
                p_sanitized_message,

            failure_event_id =
                v_failure_event_id,

            completed_at =
                now()
        where public.outbound_message_attempts.outbound_message_attempt_id =
            v_attempt.outbound_message_attempt_id
        returning *
        into v_attempt;


        v_review_key :=
            'TWILIO:OUTBOX:'
            || v_attempt.source_outbox_event_id::text
            || ':SMS_TRANSPORT_REVIEW_REQUIRED';


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
            v_attempt.call_id,
            v_outbox.source_raw_provider_event_id,
            v_attempt.correlation_id,
            jsonb_build_object(
                'stage',
                    'SMS_TRANSPORT_UNKNOWN',

                'source_outbox_event_id',
                    v_attempt.source_outbox_event_id,

                'outbound_message_attempt_id',
                    v_attempt.outbound_message_attempt_id,

                'outbox_attempt_number',
                    v_attempt.outbox_attempt_number,

                'call_id',
                    v_attempt.call_id,

                'prospect_id',
                    v_attempt.prospect_id,

                'contact_point_id',
                    v_attempt.contact_point_id,

                'provider',
                    'TWILIO',

                'to_phone',
                    v_attempt.to_phone,

                'template_code',
                    v_attempt.template_code,

                'decision',
                    'REVIEW_REQUIRED',

                'reason_code',
                    'PROVIDER_OUTCOME_UNKNOWN'
            )
        )
        on conflict (
            event_key
        )
        do nothing;


        select outbox_event_id
        into v_review_outbox_event_id
        from public.outbox_events
        where event_key =
            v_review_key;


        update public.outbound_message_attempts
        set review_outbox_event_id =
            v_review_outbox_event_id
        where public.outbound_message_attempts.outbound_message_attempt_id =
            v_attempt.outbound_message_attempt_id;


        return query
        select
            'REVIEW_REQUIRED'::text,
            'COMPLETE_OUTBOX'::text,

            'UNKNOWN'::text,

            v_attempt.outbound_message_attempt_id,
            v_attempt.source_outbox_event_id,
            v_attempt.outbox_attempt_number,

            v_attempt.provider_message_id,

            v_attempt.conversation_id,
            v_attempt.message_id,

            v_failure_event_id,
            v_review_outbox_event_id,

            null::integer,

            'PROVIDER_OUTCOME_UNKNOWN'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Definitive non-retryable REJECTED outcome.
    -- ------------------------------------------------------------------------

    update public.outbound_message_attempts
    set
        state =
            'REJECTED_FINAL',

        provider_status =
            nullif(
                btrim(
                    coalesce(
                        p_provider_status,
                        ''
                    )
                ),
                ''
            ),

        retryable =
            false,

        error_code =
            nullif(
                btrim(
                    coalesce(
                        p_error_code,
                        ''
                    )
                ),
                ''
            ),

        sanitized_message =
            p_sanitized_message,

        failure_event_id =
            v_failure_event_id,

        completed_at =
            now()
    where public.outbound_message_attempts.outbound_message_attempt_id =
        v_attempt.outbound_message_attempt_id
    returning *
    into v_attempt;


    v_review_key :=
        'TWILIO:OUTBOX:'
        || v_attempt.source_outbox_event_id::text
        || ':SMS_TRANSPORT_REVIEW_REQUIRED';


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
        v_attempt.call_id,
        v_outbox.source_raw_provider_event_id,
        v_attempt.correlation_id,
        jsonb_build_object(
            'stage',
                'SMS_TRANSPORT_REJECTED',

            'source_outbox_event_id',
                v_attempt.source_outbox_event_id,

            'outbound_message_attempt_id',
                v_attempt.outbound_message_attempt_id,

            'outbox_attempt_number',
                v_attempt.outbox_attempt_number,

            'call_id',
                v_attempt.call_id,

            'prospect_id',
                v_attempt.prospect_id,

            'contact_point_id',
                v_attempt.contact_point_id,

            'provider',
                'TWILIO',

            'to_phone',
                v_attempt.to_phone,

            'template_code',
                v_attempt.template_code,

            'decision',
                'REVIEW_REQUIRED',

            'reason_code',
                'NON_RETRYABLE_PROVIDER_REJECTION',

            'error_code',
                nullif(
                    btrim(
                        coalesce(
                            p_error_code,
                            ''
                        )
                    ),
                    ''
                )
        )
    )
    on conflict (
        event_key
    )
    do nothing;


    select outbox_event_id
    into v_review_outbox_event_id
    from public.outbox_events
    where event_key =
        v_review_key;


    update public.outbound_message_attempts
    set review_outbox_event_id =
        v_review_outbox_event_id
    where public.outbound_message_attempts.outbound_message_attempt_id =
        v_attempt.outbound_message_attempt_id;


    return query
    select
        'REJECTED_FINAL'::text,
        'COMPLETE_OUTBOX'::text,

        'REJECTED_FINAL'::text,

        v_attempt.outbound_message_attempt_id,
        v_attempt.source_outbox_event_id,
        v_attempt.outbox_attempt_number,

        v_attempt.provider_message_id,

        v_attempt.conversation_id,
        v_attempt.message_id,

        v_failure_event_id,
        v_review_outbox_event_id,

        null::integer,

        'NON_RETRYABLE_PROVIDER_REJECTION'::text;
end;
$function$;


revoke all
on function public.finalize_twilio_recovery_sms_attempt_v1(
    uuid,
    text,
    text,
    text,
    text,
    boolean,
    text,
    text,
    text
)
from public, anon, authenticated;


grant execute
on function public.finalize_twilio_recovery_sms_attempt_v1(
    uuid,
    text,
    text,
    text,
    text,
    boolean,
    text,
    text,
    text
)
to service_role;



comment on table public.outbound_message_attempts is
'Durable outbound provider-boundary ledger. A SENDING attempt from an older outbox claim is treated as ambiguous and never authorizes an automatic resend.';


comment on function public.begin_twilio_recovery_sms_attempt_v1(
    uuid,
    text
) is
'Runs the current Phase 6C.1 safety gate and durably reserves one Twilio SMS provider boundary for the current claimed outbox attempt.';


comment on function public.finalize_twilio_recovery_sms_attempt_v1(
    uuid,
    text,
    text,
    text,
    text,
    boolean,
    text,
    text,
    text
) is
'Atomically persists accepted Twilio SMS messages or records rejected/unknown provider outcomes without unsafe automatic resend.';