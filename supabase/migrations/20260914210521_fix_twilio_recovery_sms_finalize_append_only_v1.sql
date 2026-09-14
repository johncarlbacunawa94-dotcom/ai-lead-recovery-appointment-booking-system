-- Phase 6C.4 corrective migration.
-- messages is append-only for service_role.
-- Finalization is serialized by the outbox + provider-attempt locks;
-- message uniqueness is protected by existing unique indexes.

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
        limit 1;


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