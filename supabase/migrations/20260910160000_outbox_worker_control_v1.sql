-- ============================================================================
-- Phase 4: Reliable asynchronous outbox worker control
--
-- Purpose:
--   Provide deterministic worker claiming, completion, retry, stale-lock
--   recovery, and dead-letter behavior for asynchronous outbox processing.
--
-- Authority rules:
--   - workers identify themselves explicitly;
--   - claiming is atomic and uses row locking with SKIP LOCKED;
--   - one active lease exists per outbox row;
--   - every claim increments attempts exactly once;
--   - crashed/stale workers may be safely reclaimed after lease expiry;
--   - completion/failure requires current lock ownership;
--   - exhausted events move to DEAD_LETTER;
--   - only service_role may execute these RPCs.
-- ============================================================================


-- ============================================================================
-- 1. CLAIM
-- ============================================================================

create or replace function public.claim_outbox_events_v1(
    p_worker_id text,
    p_event_types text[],
    p_limit integer default 10,
    p_lock_timeout_seconds integer default 300
)
returns table (
    outbox_event_id uuid,
    event_key text,
    event_type text,
    aggregate_type text,
    aggregate_id uuid,
    source_raw_provider_event_id uuid,
    correlation_id uuid,
    payload jsonb,
    attempts integer,
    max_attempts integer,
    claimed_at timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_worker_id text;
    v_event_types text[];
begin
    --------------------------------------------------------------------------
    -- Validate worker identity.
    --------------------------------------------------------------------------

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


    if length(v_worker_id) > 200 then
        raise exception
            'worker ID exceeds maximum length'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- Normalize event-type filter.
    --------------------------------------------------------------------------

    select array_agg(
        distinct upper(
            btrim(value)
        )
    )
    into v_event_types
    from unnest(
        coalesce(
            p_event_types,
            array[]::text[]
        )
    ) as requested(value)
    where nullif(
        btrim(
            coalesce(
                value,
                ''
            )
        ),
        ''
    ) is not null;


    if (
        v_event_types is null
        or cardinality(v_event_types) = 0
    ) then
        raise exception
            'at least one event type is required'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- Validate claim controls.
    --------------------------------------------------------------------------

    if (
        p_limit is null
        or p_limit < 1
        or p_limit > 100
    ) then
        raise exception
            'claim limit must be between 1 and 100'
            using errcode = '22023';
    end if;


    if (
        p_lock_timeout_seconds is null
        or p_lock_timeout_seconds < 30
        or p_lock_timeout_seconds > 3600
    ) then
        raise exception
            'lock timeout must be between 30 and 3600 seconds'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- Defensive dead-letter cleanup.
    --
    -- FAILED/PENDING rows with no attempts remaining must never be claimed.
    -- Stale PROCESSING rows on their final consumed attempt are also terminal.
    --------------------------------------------------------------------------

    update public.outbox_events as oe
    set
        status = 'DEAD_LETTER',

        locked_at = null,

        locked_by = null,

        last_error =
            coalesce(
                oe.last_error,
                'maximum processing attempts exhausted'
            )
    where oe.event_type = any(v_event_types)
      and (
        (
            oe.status in (
                'PENDING',
                'FAILED'
            )
            and oe.attempts >=
                oe.max_attempts
        )
        or
        (
            oe.status = 'PROCESSING'
            and oe.attempts >=
                oe.max_attempts
            and (
                oe.locked_at is null
                or oe.locked_at <=
                    now() -
                    make_interval(
                        secs =>
                            p_lock_timeout_seconds
                    )
            )
        )
    );


    --------------------------------------------------------------------------
    -- Atomically claim eligible work.
    --
    -- SKIP LOCKED prevents competing workers from claiming the same row.
    -- Stale PROCESSING leases may be reclaimed when attempts remain.
    --------------------------------------------------------------------------

    return query
    with candidates as (
        select
            oe.outbox_event_id
        from public.outbox_events as oe
        where oe.event_type =
            any(v_event_types)
          and oe.attempts <
            oe.max_attempts
          and (
              (
                  oe.status in (
                      'PENDING',
                      'FAILED'
                  )
                  and oe.available_at <=
                      now()
              )
              or
              (
                  oe.status =
                      'PROCESSING'
                  and (
                      oe.locked_at is null
                      or oe.locked_at <=
                          now() -
                          make_interval(
                              secs =>
                                  p_lock_timeout_seconds
                          )
                  )
              )
          )
        order by
            oe.available_at asc,
            oe.created_at asc,
            oe.outbox_event_id asc
        for update skip locked
        limit p_limit
    ),
    claimed as (
        update public.outbox_events as oe
        set
            status =
                'PROCESSING',

            locked_at =
                now(),

            locked_by =
                v_worker_id,

            attempts =
                oe.attempts + 1
        from candidates as c
        where oe.outbox_event_id =
            c.outbox_event_id
        returning
            oe.outbox_event_id,
            oe.event_key,
            oe.event_type,
            oe.aggregate_type,
            oe.aggregate_id,
            oe.source_raw_provider_event_id,
            oe.correlation_id,
            oe.payload,
            oe.attempts,
            oe.max_attempts,
            oe.locked_at
    )
    select
        c.outbox_event_id,
        c.event_key,
        c.event_type,
        c.aggregate_type,
        c.aggregate_id,
        c.source_raw_provider_event_id,
        c.correlation_id,
        c.payload,
        c.attempts,
        c.max_attempts,
        c.locked_at
    from claimed as c
    order by
        c.locked_at asc,
        c.outbox_event_id asc;
end;
$function$;


-- ============================================================================
-- 2. COMPLETE
-- ============================================================================

create or replace function public.complete_outbox_event_v1(
    p_outbox_event_id uuid,
    p_worker_id text
)
returns table (
    outbox_event_id uuid,
    status text,
    attempts integer
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_worker_id text;
    v_event public.outbox_events%rowtype;
begin
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


    select oe.*
    into v_event
    from public.outbox_events as oe
    where oe.outbox_event_id =
        p_outbox_event_id
    for update;


    if not found then
        raise exception
            'outbox event does not exist'
            using errcode = '22023';
    end if;


    if v_event.status <> 'PROCESSING' then
        raise exception
            'outbox event is not currently processing'
            using errcode = '22000';
    end if;


    if v_event.locked_by is distinct from
        v_worker_id
    then
        raise exception
            'worker does not own the outbox event lease'
            using errcode = '22000';
    end if;


    update public.outbox_events as oe
    set
        status =
            'PROCESSED',

        locked_at =
            null,

        locked_by =
            null,

        last_error =
            null
    where oe.outbox_event_id =
        v_event.outbox_event_id
    returning
        oe.outbox_event_id,
        oe.status,
        oe.attempts
    into
        outbox_event_id,
        status,
        attempts;


    return next;
end;
$function$;


-- ============================================================================
-- 3. FAIL / RETRY / DEAD LETTER
-- ============================================================================

create or replace function public.fail_outbox_event_v1(
    p_outbox_event_id uuid,
    p_worker_id text,
    p_error text,
    p_retry_after_seconds integer default 60
)
returns table (
    outbox_event_id uuid,
    status text,
    attempts integer,
    max_attempts integer,
    available_at timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_worker_id text;
    v_error text;
    v_event public.outbox_events%rowtype;
    v_next_status text;
begin
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


    v_error :=
        nullif(
            btrim(
                coalesce(
                    p_error,
                    ''
                )
            ),
            ''
        );


    if v_error is null then
        raise exception
            'failure reason is required'
            using errcode = '22023';
    end if;


    if (
        p_retry_after_seconds is null
        or p_retry_after_seconds < 0
        or p_retry_after_seconds > 86400
    ) then
        raise exception
            'retry delay must be between 0 and 86400 seconds'
            using errcode = '22023';
    end if;


    select oe.*
    into v_event
    from public.outbox_events as oe
    where oe.outbox_event_id =
        p_outbox_event_id
    for update;


    if not found then
        raise exception
            'outbox event does not exist'
            using errcode = '22023';
    end if;


    if v_event.status <> 'PROCESSING' then
        raise exception
            'outbox event is not currently processing'
            using errcode = '22000';
    end if;


    if v_event.locked_by is distinct from
        v_worker_id
    then
        raise exception
            'worker does not own the outbox event lease'
            using errcode = '22000';
    end if;


    if v_event.attempts >=
        v_event.max_attempts
    then
        v_next_status :=
            'DEAD_LETTER';
    else
        v_next_status :=
            'FAILED';
    end if;


    update public.outbox_events as oe
    set
        status =
            v_next_status,

        available_at =
            case
                when v_next_status =
                    'FAILED'
                then
                    now() +
                    make_interval(
                        secs =>
                            p_retry_after_seconds
                    )
                else
                    oe.available_at
            end,

        locked_at =
            null,

        locked_by =
            null,

        last_error =
            v_error
    where oe.outbox_event_id =
        v_event.outbox_event_id
    returning
        oe.outbox_event_id,
        oe.status,
        oe.attempts,
        oe.max_attempts,
        oe.available_at
    into
        outbox_event_id,
        status,
        attempts,
        max_attempts,
        available_at;


    return next;
end;
$function$;


-- ============================================================================
-- Trusted execution boundaries.
-- ============================================================================

revoke all
on function public.claim_outbox_events_v1(
    text,
    text[],
    integer,
    integer
)
from public;

revoke all
on function public.claim_outbox_events_v1(
    text,
    text[],
    integer,
    integer
)
from anon;

revoke all
on function public.claim_outbox_events_v1(
    text,
    text[],
    integer,
    integer
)
from authenticated;

grant execute
on function public.claim_outbox_events_v1(
    text,
    text[],
    integer,
    integer
)
to service_role;


revoke all
on function public.complete_outbox_event_v1(
    uuid,
    text
)
from public;

revoke all
on function public.complete_outbox_event_v1(
    uuid,
    text
)
from anon;

revoke all
on function public.complete_outbox_event_v1(
    uuid,
    text
)
from authenticated;

grant execute
on function public.complete_outbox_event_v1(
    uuid,
    text
)
to service_role;


revoke all
on function public.fail_outbox_event_v1(
    uuid,
    text,
    text,
    integer
)
from public;

revoke all
on function public.fail_outbox_event_v1(
    uuid,
    text,
    text,
    integer
)
from anon;

revoke all
on function public.fail_outbox_event_v1(
    uuid,
    text,
    text,
    integer
)
from authenticated;

grant execute
on function public.fail_outbox_event_v1(
    uuid,
    text,
    text,
    integer
)
to service_role;