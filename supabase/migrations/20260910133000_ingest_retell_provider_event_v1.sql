-- ============================================================================
-- Phase 4 / Step 1: Atomic Retell provider-event ingestion
--
-- Purpose:
--   Persist an authenticated Retell lifecycle event and create its asynchronous
--   outbox work item atomically.
--
-- Authority rules:
--   - Retell signature verification occurs before this RPC is called;
--   - provider is fixed to RETELL;
--   - lifecycle event identity is deterministic: event + provider call ID;
--   - raw provider evidence is append-only;
--   - replayed deliveries do not create duplicate raw or outbox rows;
--   - no AI inference or business-state mutation occurs here.
-- ============================================================================

create or replace function public.ingest_retell_provider_event_v1(
    p_event_type text,
    p_provider_call_id text,
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
    v_provider_call_id text;
    v_payload_hash text;

    v_event_key text;
    v_outbox_event_type text;

    v_raw public.raw_provider_events%rowtype;
    v_outbox public.outbox_events%rowtype;

    v_disposition text;
begin
    --------------------------------------------------------------------------
    -- Normalize and validate provider-event identity.
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
        'call_started',
        'call_ended',
        'call_analyzed'
    ) then
        raise exception
            'unsupported Retell lifecycle event type'
            using errcode = '22023';
    end if;


    v_provider_call_id :=
        btrim(
            coalesce(
                p_provider_call_id,
                ''
            )
        );

    if v_provider_call_id = '' then
        raise exception
            'Retell provider call ID is required'
            using errcode = '22023';
    end if;


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
    -- Structured arguments must agree with the authenticated payload.
    --------------------------------------------------------------------------

    if coalesce(
        p_payload ->> 'event',
        ''
    ) <> v_event_type then
        raise exception
            'provider payload event type does not match the requested event type'
            using errcode = '22023';
    end if;


    if coalesce(
        p_payload #>> '{call,call_id}',
        ''
    ) <> v_provider_call_id then
        raise exception
            'provider payload call ID does not match the requested provider call ID'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- Deterministic provider-event identity.
    --------------------------------------------------------------------------

    v_event_key :=
        'RETELL:' ||
        v_provider_call_id ||
        ':' ||
        v_event_type;


    v_outbox_event_type :=
        case v_event_type
            when 'call_started'
                then 'RETELL_CALL_STARTED'
            when 'call_ended'
                then 'RETELL_CALL_ENDED'
            when 'call_analyzed'
                then 'RETELL_CALL_ANALYZED'
        end;


    --------------------------------------------------------------------------
    -- Persist raw authenticated provider evidence.
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
        'RETELL',
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
        v_disposition := 'ACCEPTED';
    else
        ----------------------------------------------------------------------
        -- Replay path. Existing authenticated event wins.
        ----------------------------------------------------------------------

        select rpe.*
        into v_raw
        from public.raw_provider_events as rpe
        where rpe.provider = 'RETELL'
          and rpe.event_key = v_event_key;


        if not found then
            raise exception
                'provider event replay could not be resolved'
                using errcode = 'P0001';
        end if;


        ----------------------------------------------------------------------
        -- Byte serialization may differ on a legitimate retry, but semantic
        -- JSON for the same lifecycle event must remain identical.
        ----------------------------------------------------------------------

        if v_raw.payload <> p_payload then
            raise exception
                'provider event key was reused with a conflicting payload'
                using errcode = '22000';
        end if;


        v_disposition := 'REPLAY';
    end if;


    --------------------------------------------------------------------------
    -- Create asynchronous work item in the same database transaction.
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
        'CALL',
        null,
        v_raw.raw_provider_event_id,
        v_raw.correlation_id,
        jsonb_build_object(
            'provider',
            'RETELL',
            'provider_event_type',
            v_event_type,
            'provider_call_id',
            v_provider_call_id,
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
                'provider event outbox replay could not be resolved'
                using errcode = 'P0001';
        end if;
    end if;


    --------------------------------------------------------------------------
    -- Defensive consistency checks across the atomic pair.
    --------------------------------------------------------------------------

    if (
        v_outbox.source_raw_provider_event_id
            is distinct from
        v_raw.raw_provider_event_id
    ) then
        raise exception
            'outbox event points to a conflicting raw provider event'
            using errcode = '22000';
    end if;


    if (
        v_outbox.correlation_id
            is distinct from
        v_raw.correlation_id
    ) then
        raise exception
            'outbox and raw provider event correlation IDs do not match'
            using errcode = '22000';
    end if;


    if v_outbox.event_type <> v_outbox_event_type then
        raise exception
            'outbox event type conflicts with provider lifecycle event'
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


-- ============================================================================
-- Trusted execution boundary.
--
-- Retell never executes this RPC directly. Only the trusted Supabase Edge
-- Function using the service role may execute it.
-- ============================================================================

revoke all
on function public.ingest_retell_provider_event_v1(
    text,
    text,
    text,
    jsonb
)
from public;

revoke all
on function public.ingest_retell_provider_event_v1(
    text,
    text,
    text,
    jsonb
)
from anon;

revoke all
on function public.ingest_retell_provider_event_v1(
    text,
    text,
    text,
    jsonb
)
from authenticated;

grant execute
on function public.ingest_retell_provider_event_v1(
    text,
    text,
    text,
    jsonb
)
to service_role;