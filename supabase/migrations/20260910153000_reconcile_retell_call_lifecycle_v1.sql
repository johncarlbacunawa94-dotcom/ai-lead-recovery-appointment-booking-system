-- ============================================================================
-- Phase 4 / Step 2: Deterministic Retell call lifecycle reconciliation
--
-- Purpose:
--   Reconcile one authenticated, persisted Retell lifecycle event against the
--   canonical calls table.
--
-- Canonical lifecycle:
--   REGISTERED -> ACTIVE -> ENDED -> ANALYSIS_PENDING
--   ANALYZED and POST_PROCESSED are owned by later post-call processing.
--
-- Authority rules:
--   - only persisted, signature-verified RETELL raw events are accepted;
--   - provider call IDs and canonical call IDs remain server-owned;
--   - provider events may advance but never regress canonical call state;
--   - Retell call_analyzed means provider analysis is available and therefore
--     places our own post-call analysis into ANALYSIS_PENDING;
--   - no prospect/opportunity/booking state is changed here;
--   - no AI inference occurs here.
-- ============================================================================

create or replace function public.reconcile_retell_call_lifecycle_v1(
    p_raw_provider_event_id uuid
)
returns table (
    disposition text,
    call_id uuid,
    provider_call_id text,
    event_type text,
    previous_status text,
    current_status text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_raw public.raw_provider_events%rowtype;
    v_call_payload jsonb;

    v_provider_call_id text;
    v_event_type text;

    v_provider_call_type text;
    v_call_type text;

    v_provider_direction text;
    v_direction text;

    v_provider_status text;
    v_disconnection_reason text;

    v_start_ms bigint;
    v_end_ms bigint;
    v_duration_bigint bigint;

    v_started_at timestamptz;
    v_ended_at timestamptz;
    v_duration_ms integer;

    v_target_status text;
    v_previous_status text;
    v_current_status text;

    v_existing public.calls%rowtype;
    v_result public.calls%rowtype;

    v_expected_event_key text;
    v_disposition text;
begin
    --------------------------------------------------------------------------
    -- 1. Load only immutable authenticated provider evidence.
    --------------------------------------------------------------------------

    select rpe.*
    into v_raw
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id = p_raw_provider_event_id;


    if not found then
        raise exception
            'raw provider event does not exist'
            using errcode = '22023';
    end if;


    if v_raw.provider <> 'RETELL' then
        raise exception
            'raw provider event is not a Retell event'
            using errcode = '22023';
    end if;


    if v_raw.signature_valid is distinct from true then
        raise exception
            'raw provider event is not signature verified'
            using errcode = '22023';
    end if;


    v_event_type :=
        lower(
            btrim(
                coalesce(
                    v_raw.event_type,
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
            'raw provider event type is not a supported call lifecycle event'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 2. Validate the persisted Retell call envelope.
    --------------------------------------------------------------------------

    v_call_payload :=
        v_raw.payload -> 'call';


    if (
        v_call_payload is null
        or jsonb_typeof(v_call_payload) <> 'object'
    ) then
        raise exception
            'Retell lifecycle event has no valid call object'
            using errcode = '22023';
    end if;


    v_provider_call_id :=
        nullif(
            btrim(
                coalesce(
                    v_call_payload ->> 'call_id',
                    ''
                )
            ),
            ''
        );


    if v_provider_call_id is null then
        raise exception
            'Retell lifecycle event has no call_id'
            using errcode = '22023';
    end if;


    if coalesce(
        v_raw.payload ->> 'event',
        ''
    ) <> v_event_type then
        raise exception
            'raw event type does not match provider payload'
            using errcode = '22023';
    end if;


    v_expected_event_key :=
        'RETELL:' ||
        v_provider_call_id ||
        ':' ||
        v_event_type;


    if v_raw.event_key <> v_expected_event_key then
        raise exception
            'raw provider event key does not match its Retell payload'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 3. Resolve canonical call type.
    --------------------------------------------------------------------------

    v_provider_call_type :=
        lower(
            btrim(
                coalesce(
                    v_call_payload ->> 'call_type',
                    ''
                )
            )
        );


    v_call_type :=
        case v_provider_call_type
            when 'web_call'
                then 'WEB'
            when 'phone_call'
                then 'PHONE'
            else null
        end;


    if v_call_type is null then
        raise exception
            'Retell call_type is unsupported'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 4. Resolve direction.
    --
    -- Phase 2B policy: browser/web calls are inbound lead-entry calls.
    -- Phone direction is never guessed.
    --------------------------------------------------------------------------

    v_provider_direction :=
        lower(
            btrim(
                coalesce(
                    v_call_payload ->> 'direction',
                    ''
                )
            )
        );


    if v_call_type = 'WEB' then
        v_direction := 'INBOUND';

    elsif v_provider_direction = 'inbound' then
        v_direction := 'INBOUND';

    elsif v_provider_direction = 'outbound' then
        v_direction := 'OUTBOUND';

    else
        v_direction := null;
    end if;


    --------------------------------------------------------------------------
    -- 5. Provider status and disconnection evidence.
    --------------------------------------------------------------------------

    v_provider_status :=
        lower(
            btrim(
                coalesce(
                    v_call_payload ->> 'call_status',
                    ''
                )
            )
        );


    if (
        v_provider_status <> ''
        and v_provider_status not in (
            'registered',
            'not_connected',
            'ongoing',
            'ended',
            'error'
        )
    ) then
        raise exception
            'Retell call_status is unsupported'
            using errcode = '22023';
    end if;


    v_disconnection_reason :=
        nullif(
            btrim(
                coalesce(
                    v_call_payload ->> 'disconnection_reason',
                    ''
                )
            ),
            ''
        );


    --------------------------------------------------------------------------
    -- 6. Parse authoritative provider timestamps.
    --------------------------------------------------------------------------

    if v_call_payload ? 'start_timestamp' then
        if jsonb_typeof(
            v_call_payload -> 'start_timestamp'
        ) <> 'number' then
            raise exception
                'Retell start_timestamp must be numeric'
                using errcode = '22023';
        end if;


        v_start_ms :=
            (
                v_call_payload ->>
                    'start_timestamp'
            )::bigint;


        if v_start_ms < 0 then
            raise exception
                'Retell start_timestamp cannot be negative'
                using errcode = '22023';
        end if;


        v_started_at :=
            to_timestamp(
                v_start_ms::double precision /
                1000.0
            );
    end if;


    if v_call_payload ? 'end_timestamp' then
        if jsonb_typeof(
            v_call_payload -> 'end_timestamp'
        ) <> 'number' then
            raise exception
                'Retell end_timestamp must be numeric'
                using errcode = '22023';
        end if;


        v_end_ms :=
            (
                v_call_payload ->>
                    'end_timestamp'
            )::bigint;


        if v_end_ms < 0 then
            raise exception
                'Retell end_timestamp cannot be negative'
                using errcode = '22023';
        end if;


        v_ended_at :=
            to_timestamp(
                v_end_ms::double precision /
                1000.0
            );
    end if;


    if (
        v_started_at is not null
        and v_ended_at is not null
        and v_ended_at < v_started_at
    ) then
        raise exception
            'Retell call end timestamp precedes start timestamp'
            using errcode = '22023';
    end if;


    if v_call_payload ? 'duration_ms' then
        if jsonb_typeof(
            v_call_payload -> 'duration_ms'
        ) <> 'number' then
            raise exception
                'Retell duration_ms must be numeric'
                using errcode = '22023';
        end if;


        v_duration_bigint :=
            (
                v_call_payload ->>
                    'duration_ms'
            )::bigint;


        if (
            v_duration_bigint < 0
            or v_duration_bigint > 2147483647
        ) then
            raise exception
                'Retell duration_ms is outside the supported range'
                using errcode = '22023';
        end if;


        v_duration_ms :=
            v_duration_bigint::integer;
    end if;


    --------------------------------------------------------------------------
    -- 7. Map provider lifecycle event into our canonical lifecycle.
    --
    -- call_analyzed does NOT mean our PostCallAnalysisV1 has completed.
    -- It means enough provider evidence exists to start that later work.
    --------------------------------------------------------------------------

    if (
        v_provider_status = 'error'
        or v_provider_status = 'not_connected'
    ) then
        v_target_status := 'FAILED';

    elsif v_event_type = 'call_started' then
        v_target_status := 'ACTIVE';

    elsif v_event_type = 'call_ended' then
        v_target_status := 'ENDED';

    else
        v_target_status := 'ANALYSIS_PENDING';
    end if;


    --------------------------------------------------------------------------
    -- 8. Serialize all lifecycle work for one Retell call.
    --
    -- A call_started event is not guaranteed to exist. Advisory locking lets
    -- a later call_ended/call_analyzed event safely create the canonical row
    -- without racing another event for the same provider call.
    --------------------------------------------------------------------------

    perform pg_advisory_xact_lock(
        hashtextextended(
            'RETELL:' ||
            v_provider_call_id,
            0
        )
    );


    select c.*
    into v_existing
    from public.calls as c
    where c.provider = 'RETELL'
      and c.provider_call_id =
            v_provider_call_id
    for update;


    --------------------------------------------------------------------------
    -- 9. Create canonical call if no prior synchronous tool/event did.
    --------------------------------------------------------------------------

    if not found then
        if (
            v_call_type = 'PHONE'
            and v_direction is null
        ) then
            raise exception
                'new Retell phone call requires authoritative direction'
                using errcode = '22023';
        end if;


        insert into public.calls (
            provider,
            provider_call_id,
            call_type,
            direction,
            status,
            disconnection_reason,
            started_at,
            ended_at,
            duration_ms
        )
        values (
            'RETELL',
            v_provider_call_id,
            v_call_type,
            v_direction,
            v_target_status,
            v_disconnection_reason,
            v_started_at,
            v_ended_at,
            v_duration_ms
        )
        returning *
        into v_result;


        v_disposition :=
            'CREATED';

        v_previous_status :=
            null;

        v_current_status :=
            v_result.status;


    else
        ----------------------------------------------------------------------
        -- 10. Existing canonical identity is authoritative.
        ----------------------------------------------------------------------

        if v_existing.call_type <> v_call_type then
            raise exception
                'Retell call_type conflicts with canonical call'
                using errcode = '22000';
        end if;


        if (
            v_direction is not null
            and v_existing.direction <>
                v_direction
        ) then
            raise exception
                'Retell direction conflicts with canonical call'
                using errcode = '22000';
        end if;


        if (
            v_existing.started_at is not null
            and v_started_at is not null
            and v_existing.started_at is distinct from
                v_started_at
        ) then
            raise exception
                'Retell start timestamp conflicts with canonical call'
                using errcode = '22000';
        end if;


        if (
            v_existing.ended_at is not null
            and v_ended_at is not null
            and v_existing.ended_at is distinct from
                v_ended_at
        ) then
            raise exception
                'Retell end timestamp conflicts with canonical call'
                using errcode = '22000';
        end if;


        if (
            v_existing.duration_ms is not null
            and v_duration_ms is not null
            and v_existing.duration_ms <>
                v_duration_ms
        ) then
            raise exception
                'Retell duration conflicts with canonical call'
                using errcode = '22000';
        end if;


        if (
            v_existing.disconnection_reason is not null
            and v_disconnection_reason is not null
            and v_existing.disconnection_reason <>
                v_disconnection_reason
        ) then
            raise exception
                'Retell disconnection reason conflicts with canonical call'
                using errcode = '22000';
        end if;


        v_previous_status :=
            v_existing.status;


        ----------------------------------------------------------------------
        -- Monotonic state advancement.
        ----------------------------------------------------------------------

        v_current_status :=
            case
                when v_existing.status in (
                    'POST_PROCESSED',
                    'ANALYZED',
                    'FAILED'
                )
                    then v_existing.status

                when v_target_status = 'FAILED'
                    then 'FAILED'

                when v_target_status = 'ACTIVE'
                    then
                        case
                            when v_existing.status = 'REGISTERED'
                                then 'ACTIVE'
                            else v_existing.status
                        end

                when v_target_status = 'ENDED'
                    then
                        case
                            when v_existing.status in (
                                'REGISTERED',
                                'ACTIVE'
                            )
                                then 'ENDED'
                            else v_existing.status
                        end

                when v_target_status = 'ANALYSIS_PENDING'
                    then
                        case
                            when v_existing.status in (
                                'REGISTERED',
                                'ACTIVE',
                                'ENDED'
                            )
                                then 'ANALYSIS_PENDING'
                            else v_existing.status
                        end

                else v_existing.status
            end;


        update public.calls as c
        set
            status =
                v_current_status,

            started_at =
                coalesce(
                    c.started_at,
                    v_started_at
                ),

            ended_at =
                coalesce(
                    c.ended_at,
                    v_ended_at
                ),

            duration_ms =
                coalesce(
                    c.duration_ms,
                    v_duration_ms
                ),

            disconnection_reason =
                coalesce(
                    c.disconnection_reason,
                    v_disconnection_reason
                )
        where c.call_id =
            v_existing.call_id
        returning *
        into v_result;


        if (
            v_result.status is distinct from
                v_previous_status
            or v_existing.started_at is distinct from
                v_result.started_at
            or v_existing.ended_at is distinct from
                v_result.ended_at
            or v_existing.duration_ms is distinct from
                v_result.duration_ms
            or v_existing.disconnection_reason is distinct from
                v_result.disconnection_reason
        ) then
            v_disposition :=
                'UPDATED';
        else
            v_disposition :=
                'UNCHANGED';
        end if;


        v_current_status :=
            v_result.status;
    end if;


    --------------------------------------------------------------------------
    -- 11. Bind the existing outbox envelope to the resolved canonical call.
    --------------------------------------------------------------------------

    if exists (
        select 1
        from public.outbox_events as oe
        where oe.source_raw_provider_event_id =
            v_raw.raw_provider_event_id
          and oe.aggregate_id is not null
          and oe.aggregate_id <>
            v_result.call_id
    ) then
        raise exception
            'provider-event outbox is already bound to another canonical call'
            using errcode = '22000';
    end if;


    update public.outbox_events as oe
    set aggregate_id =
        v_result.call_id
    where oe.source_raw_provider_event_id =
        v_raw.raw_provider_event_id
      and oe.aggregate_type = 'CALL'
      and oe.aggregate_id is null;


    --------------------------------------------------------------------------
    -- 12. Return deterministic reconciliation result.
    --------------------------------------------------------------------------

    return query
    select
        v_disposition,
        v_result.call_id,
        v_provider_call_id,
        v_event_type,
        v_previous_status,
        v_current_status;
end;
$function$;


-- ============================================================================
-- Trusted execution boundary.
-- ============================================================================

revoke all
on function public.reconcile_retell_call_lifecycle_v1(
    uuid
)
from public;

revoke all
on function public.reconcile_retell_call_lifecycle_v1(
    uuid
)
from anon;

revoke all
on function public.reconcile_retell_call_lifecycle_v1(
    uuid
)
from authenticated;

grant execute
on function public.reconcile_retell_call_lifecycle_v1(
    uuid
)
to service_role;