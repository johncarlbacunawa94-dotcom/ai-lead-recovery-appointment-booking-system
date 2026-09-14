-- ============================================================================
-- Phase 6A: Atomic Twilio provider-event ingress
--
-- Authenticated Twilio evidence and its asynchronous outbox work item are
-- persisted in one PostgreSQL transaction.
--
-- Supported normalized event families:
--   voice_status
--   incoming_message
--   message_status
-- ============================================================================

create or replace function public.ingest_twilio_provider_event_v1(
    p_event_type text,
    p_payload_hash text,
    p_payload jsonb
)
returns table (
    disposition text,
    raw_provider_event_id uuid,
    outbox_event_id uuid,
    correlation_id uuid,
    event_key text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_event_type text;
    v_payload_hash text;

    v_provider_resource_id text;
    v_provider_status text;
    v_sequence_number integer;

    v_event_key text;
    v_outbox_event_type text;
    v_aggregate_type text;

    v_raw public.raw_provider_events%rowtype;
    v_outbox public.outbox_events%rowtype;

    v_disposition text;
begin
    --------------------------------------------------------------------------
    -- 1. Normalize and validate the supported provider event family.
    --------------------------------------------------------------------------

    v_event_type :=
        lower(
            btrim(
                coalesce(
                    p_event_type,
                    ''
                )
            )
        );

    if v_event_type not in (
        'voice_status',
        'incoming_message',
        'message_status'
    ) then
        raise exception
            'unsupported Twilio provider event type'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 2. Validate authenticated payload evidence.
    --------------------------------------------------------------------------

    v_payload_hash :=
        lower(
            btrim(
                coalesce(
                    p_payload_hash,
                    ''
                )
            )
        );

    if v_payload_hash !~ '^[0-9a-f]{64}$' then
        raise exception
            'provider payload hash must be a SHA-256 hex digest'
            using errcode = '22023';
    end if;


    if (
        p_payload is null
        or jsonb_typeof(p_payload) <> 'object'
    ) then
        raise exception
            'provider payload must be a JSON object'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 3. Resolve deterministic Twilio event identity.
    --------------------------------------------------------------------------

    case v_event_type

        ----------------------------------------------------------------------
        -- Twilio Voice StatusCallback.
        --
        -- SequenceNumber is the provider ordering identity for separate
        -- callback requests belonging to the same CallSid.
        ----------------------------------------------------------------------

        when 'voice_status' then
            v_provider_resource_id :=
                nullif(
                    btrim(
                        coalesce(
                            p_payload ->> 'CallSid',
                            ''
                        )
                    ),
                    ''
                );

            v_provider_status :=
                lower(
                    btrim(
                        coalesce(
                            p_payload ->> 'CallStatus',
                            ''
                        )
                    )
                );


            if v_provider_resource_id is null then
                raise exception
                    'Twilio voice status event requires CallSid'
                    using errcode = '22023';
            end if;


            if v_provider_status = '' then
                raise exception
                    'Twilio voice status event requires CallStatus'
                    using errcode = '22023';
            end if;


            begin
                v_sequence_number :=
                    (
                        p_payload ->> 'SequenceNumber'
                    )::integer;
            exception
                when invalid_text_representation then
                    raise exception
                        'Twilio voice status SequenceNumber must be an integer'
                        using errcode = '22023';
            end;


            if (
                v_sequence_number is null
                or v_sequence_number < 0
            ) then
                raise exception
                    'Twilio voice status event requires non-negative SequenceNumber'
                    using errcode = '22023';
            end if;


            v_event_key :=
                'TWILIO:CALL:' ||
                v_provider_resource_id ||
                ':STATUS:' ||
                v_sequence_number::text;

            v_outbox_event_type :=
                'TWILIO_VOICE_STATUS';

            v_aggregate_type :=
                'CALL';


        ----------------------------------------------------------------------
        -- Twilio inbound SMS/MMS webhook.
        ----------------------------------------------------------------------

        when 'incoming_message' then
            v_provider_resource_id :=
                nullif(
                    btrim(
                        coalesce(
                            p_payload ->> 'MessageSid',
                            ''
                        )
                    ),
                    ''
                );


            if v_provider_resource_id is null then
                raise exception
                    'Twilio inbound message requires MessageSid'
                    using errcode = '22023';
            end if;


            if nullif(
                btrim(
                    coalesce(
                        p_payload ->> 'From',
                        ''
                    )
                ),
                ''
            ) is null then
                raise exception
                    'Twilio inbound message requires From'
                    using errcode = '22023';
            end if;


            if nullif(
                btrim(
                    coalesce(
                        p_payload ->> 'To',
                        ''
                    )
                ),
                ''
            ) is null then
                raise exception
                    'Twilio inbound message requires To'
                    using errcode = '22023';
            end if;


            v_provider_status :=
                lower(
                    btrim(
                        coalesce(
                            p_payload ->> 'SmsStatus',
                            'received'
                        )
                    )
                );


            v_event_key :=
                'TWILIO:MESSAGE:' ||
                v_provider_resource_id ||
                ':INBOUND';

            v_outbox_event_type :=
                'TWILIO_INCOMING_MESSAGE';

            v_aggregate_type :=
                'MESSAGE';


        ----------------------------------------------------------------------
        -- Twilio outbound Message StatusCallback.
        ----------------------------------------------------------------------

        when 'message_status' then
            v_provider_resource_id :=
                nullif(
                    btrim(
                        coalesce(
                            p_payload ->> 'MessageSid',
                            ''
                        )
                    ),
                    ''
                );

            v_provider_status :=
                lower(
                    btrim(
                        coalesce(
                            p_payload ->> 'MessageStatus',
                            ''
                        )
                    )
                );


            if v_provider_resource_id is null then
                raise exception
                    'Twilio message status event requires MessageSid'
                    using errcode = '22023';
            end if;


            if v_provider_status = '' then
                raise exception
                    'Twilio message status event requires MessageStatus'
                    using errcode = '22023';
            end if;


            v_event_key :=
                'TWILIO:MESSAGE:' ||
                v_provider_resource_id ||
                ':STATUS:' ||
                v_provider_status;

            v_outbox_event_type :=
                'TWILIO_MESSAGE_STATUS';

            v_aggregate_type :=
                'MESSAGE';

    end case;


    --------------------------------------------------------------------------
    -- 4. Persist authenticated provider evidence.
    --------------------------------------------------------------------------

    insert into public.raw_provider_events (
        provider,
        event_type,
        event_key,
        payload_hash,
        payload,
        signature_valid
    )
    values (
        'TWILIO',
        v_event_type,
        v_event_key,
        v_payload_hash,
        p_payload,
        true
    )
    on conflict on constraint raw_provider_events_provider_key_unique
    do nothing
    returning *
    into v_raw;


    if found then
        v_disposition :=
            'ACCEPTED';
    else
        ----------------------------------------------------------------------
        -- Replay path. Existing authenticated evidence wins.
        ----------------------------------------------------------------------

        select rpe.*
        into v_raw
        from public.raw_provider_events as rpe
        where rpe.provider = 'TWILIO'
          and rpe.event_key = v_event_key;


        if not found then
            raise exception
                'Twilio provider event replay could not be resolved'
                using errcode = 'P0001';
        end if;


        if v_raw.payload <> p_payload then
            raise exception
                'Twilio provider event key was reused with a conflicting payload'
                using errcode = '22000';
        end if;


        v_disposition :=
            'REPLAY';
    end if;


    --------------------------------------------------------------------------
    -- 5. Create asynchronous work in the same transaction.
    --------------------------------------------------------------------------

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
        v_event_key,
        v_outbox_event_type,
        v_aggregate_type,
        null,
        v_raw.raw_provider_event_id,
        v_raw.correlation_id,
        jsonb_build_object(
            'provider',
            'TWILIO',

            'provider_event_type',
            v_event_type,

            'provider_resource_id',
            v_provider_resource_id,

            'provider_status',
            v_provider_status,

            'sequence_number',
            v_sequence_number,

            'raw_provider_event_id',
            v_raw.raw_provider_event_id
        )
    )
    on conflict on constraint outbox_events_event_key_unique
    do nothing
    returning *
    into v_outbox;


    if not found then
        select oe.*
        into v_outbox
        from public.outbox_events as oe
        where oe.event_key = v_event_key;


        if not found then
            raise exception
                'Twilio provider-event outbox replay could not be resolved'
                using errcode = 'P0001';
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 6. Defensive consistency checks across the atomic pair.
    --------------------------------------------------------------------------

    if (
        v_outbox.source_raw_provider_event_id
            is distinct from
        v_raw.raw_provider_event_id
    ) then
        raise exception
            'Twilio outbox event points to conflicting raw provider evidence'
            using errcode = '22000';
    end if;


    if (
        v_outbox.correlation_id
            is distinct from
        v_raw.correlation_id
    ) then
        raise exception
            'Twilio outbox and raw provider correlation IDs do not match'
            using errcode = '22000';
    end if;


    if v_outbox.event_type <> v_outbox_event_type then
        raise exception
            'Twilio outbox event type conflicts with provider event'
            using errcode = '22000';
    end if;


    if v_outbox.aggregate_type <> v_aggregate_type then
        raise exception
            'Twilio outbox aggregate type conflicts with provider event'
            using errcode = '22000';
    end if;


    return query
    select
        v_disposition,
        v_raw.raw_provider_event_id,
        v_outbox.outbox_event_id,
        v_raw.correlation_id,
        v_event_key;
end;
$function$;


comment on function public.ingest_twilio_provider_event_v1(
    text,
    text,
    jsonb
)
is
'Phase 6A trusted Twilio ingress boundary. Atomically persists authenticated Twilio webhook evidence and its asynchronous outbox work item.';


-- ============================================================================
-- Trusted execution boundary.
--
-- Twilio never executes this RPC directly. The public webhook first validates
-- X-Twilio-Signature, then the service-role Edge Function invokes this RPC.
-- ============================================================================

revoke all
on function public.ingest_twilio_provider_event_v1(
    text,
    text,
    jsonb
)
from public;

revoke all
on function public.ingest_twilio_provider_event_v1(
    text,
    text,
    jsonb
)
from anon;

revoke all
on function public.ingest_twilio_provider_event_v1(
    text,
    text,
    jsonb
)
from authenticated;

grant execute
on function public.ingest_twilio_provider_event_v1(
    text,
    text,
    jsonb
)
to service_role;