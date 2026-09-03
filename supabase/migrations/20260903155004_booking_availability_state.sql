-- ============================================================================
-- AI Lead Recovery & Appointment Booking System
-- Migration 005: Booking Availability State
--
-- Purpose:
-- - Persist short-lived Cal.com availability requests.
-- - Persist only hashes of opaque slot tokens.
-- - Keep availability state separate from actual appointments.
-- - Allow create_appointment_v1 to validate a previously offered slot.
-- - Preserve deterministic opportunity and duplicate-booking controls.
-- ============================================================================

begin;

-- ============================================================================
-- 1. BOOKING REQUESTS
-- One server-authoritative availability request for one opportunity.
-- This is NOT an appointment.
-- ============================================================================

create table public.booking_requests (
    booking_request_id uuid primary key default gen_random_uuid(),

    prospect_id uuid not null
        references public.prospects(prospect_id),

    opportunity_id uuid not null,

    canonical_call_id uuid not null
        references public.calls(call_id),

    provider text not null default 'CAL_COM'
        check (
            provider in (
                'CAL_COM',
                'OTHER'
            )
        ),

    event_type_code text not null
        check (
            event_type_code = 'MERIDIAN_DISCOVERY_30'
        ),

    provider_event_type_id text not null,

    requested_timezone text not null,

    window_start_utc timestamptz not null,
    window_end_utc timestamptz not null,

    request_fingerprint text not null,

    status text not null default 'AVAILABILITY_REQUESTED'
        check (
            status in (
                'AVAILABILITY_REQUESTED',
                'SLOT_SELECTED',
                'BOOKING_PENDING',
                'BOOKED',
                'EXPIRED',
                'FAILED'
            )
        ),

    expires_at timestamptz not null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint booking_requests_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint booking_requests_window_order
        check (
            window_end_utc > window_start_utc
        ),

    constraint booking_requests_expiry_order
        check (
            expires_at > created_at
        )
);

create index booking_requests_opportunity_idx
    on public.booking_requests(opportunity_id);

create index booking_requests_call_idx
    on public.booking_requests(canonical_call_id);

create index booking_requests_fingerprint_idx
    on public.booking_requests(request_fingerprint);

create index booking_requests_expiry_idx
    on public.booking_requests(expires_at);

create index booking_requests_open_opportunity_idx
    on public.booking_requests(opportunity_id, created_at desc)
    where status in (
        'AVAILABILITY_REQUESTED',
        'SLOT_SELECTED',
        'BOOKING_PENDING'
    );

create trigger booking_requests_set_updated_at
before update on public.booking_requests
for each row execute function public.set_updated_at();


-- ============================================================================
-- 2. BOOKING REQUEST SLOTS
-- Candidate provider-confirmed slots returned by check availability.
--
-- Security:
-- - The usable opaque slot token is NEVER stored.
-- - Only SHA-256(slot_token) is persisted.
-- - create_appointment_v1 must hash the caller-supplied token and match it.
-- ============================================================================

create table public.booking_request_slots (
    booking_slot_id uuid primary key default gen_random_uuid(),

    booking_request_id uuid not null
        references public.booking_requests(booking_request_id)
        on delete cascade,

    slot_token_hash text not null,

    start_at_utc timestamptz not null,
    end_at_utc timestamptz not null,

    attendee_timezone text not null,

    status text not null default 'AVAILABLE'
        check (
            status in (
                'AVAILABLE',
                'SELECTED',
                'CONSUMED',
                'EXPIRED',
                'INVALIDATED'
            )
        ),

    expires_at timestamptz not null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint booking_request_slots_time_order
        check (
            end_at_utc > start_at_utc
        ),

    constraint booking_request_slots_expiry_order
        check (
            expires_at > created_at
        ),

    constraint booking_request_slots_token_hash_format
        check (
            slot_token_hash ~ '^[0-9a-f]{64}$'
        ),

    constraint booking_request_slots_request_time_unique
        unique (
            booking_request_id,
            start_at_utc,
            end_at_utc
        )
);

create unique index booking_request_slots_token_hash_unique_idx
    on public.booking_request_slots(slot_token_hash);

create index booking_request_slots_request_idx
    on public.booking_request_slots(booking_request_id);

create index booking_request_slots_expiry_idx
    on public.booking_request_slots(expires_at);

create trigger booking_request_slots_set_updated_at
before update on public.booking_request_slots
for each row execute function public.set_updated_at();


-- ============================================================================
-- 3. ATOMIC AVAILABILITY PERSISTENCE
--
-- check_appointment_availability_v1 calls Cal.com first, then passes only
-- provider-confirmed slots here.
--
-- This function re-checks booking eligibility under a row lock before
-- publishing any slot tokens.
-- ============================================================================

create or replace function public.persist_booking_availability_v1(
    p_canonical_call_id uuid,
    p_prospect_id uuid,
    p_opportunity_id uuid,
    p_event_type_code text,
    p_provider_event_type_id text,
    p_requested_timezone text,
    p_window_start_utc timestamptz,
    p_window_end_utc timestamptz,
    p_request_fingerprint text,
    p_expires_at timestamptz,
    p_slots jsonb
)
returns table (
    booking_request_id uuid,
    slot_count integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_booking_request_id uuid;
    v_slot jsonb;
    v_slot_count integer := 0;

    v_token_hash text;
    v_start_at timestamptz;
    v_end_at timestamptz;
    v_timezone text;
begin
    if p_event_type_code <> 'MERIDIAN_DISCOVERY_30' then
        raise exception 'INVALID_EVENT_TYPE_CODE';
    end if;

    if p_provider_event_type_id is null
       or btrim(p_provider_event_type_id) = '' then
        raise exception 'INVALID_PROVIDER_EVENT_TYPE_ID';
    end if;

    if p_requested_timezone is null
       or btrim(p_requested_timezone) = '' then
        raise exception 'INVALID_REQUESTED_TIMEZONE';
    end if;

    if p_request_fingerprint is null
       or btrim(p_request_fingerprint) = '' then
        raise exception 'INVALID_REQUEST_FINGERPRINT';
    end if;

    if p_window_end_utc <= p_window_start_utc then
        raise exception 'INVALID_AVAILABILITY_WINDOW';
    end if;

    if p_expires_at <= now() then
        raise exception 'INVALID_BOOKING_REQUEST_EXPIRY';
    end if;

    if jsonb_typeof(p_slots) <> 'array' then
        raise exception 'INVALID_SLOT_COLLECTION';
    end if;

    if jsonb_array_length(p_slots) < 1
       or jsonb_array_length(p_slots) > 5 then
        raise exception 'INVALID_SLOT_COUNT';
    end if;


    -- Lock the opportunity while checking the state required for booking.
    perform 1
    from public.opportunities
    where opportunity_id = p_opportunity_id
      and prospect_id = p_prospect_id
      and lifecycle_state = 'BOOKING_READY'
    for update;

    if not found then
        raise exception 'OPPORTUNITY_NOT_BOOKING_READY';
    end if;


    -- A confirmed/in-flight appointment blocks another booking attempt.
    if exists (
        select 1
        from public.appointments
        where opportunity_id = p_opportunity_id
          and status in (
              'CREATE_PENDING',
              'CONFIRMED',
              'RESCHEDULE_PENDING'
          )
    ) then
        raise exception 'ACTIVE_APPOINTMENT_EXISTS';
    end if;


    insert into public.booking_requests (
        prospect_id,
        opportunity_id,
        canonical_call_id,
        provider,
        event_type_code,
        provider_event_type_id,
        requested_timezone,
        window_start_utc,
        window_end_utc,
        request_fingerprint,
        status,
        expires_at
    )
    values (
        p_prospect_id,
        p_opportunity_id,
        p_canonical_call_id,
        'CAL_COM',
        p_event_type_code,
        p_provider_event_type_id,
        p_requested_timezone,
        p_window_start_utc,
        p_window_end_utc,
        p_request_fingerprint,
        'AVAILABILITY_REQUESTED',
        p_expires_at
    )
    returning booking_requests.booking_request_id
    into v_booking_request_id;


    for v_slot in
        select value
        from jsonb_array_elements(p_slots)
    loop
        v_token_hash :=
            lower(
                btrim(
                    coalesce(
                        v_slot ->> 'slot_token_hash',
                        ''
                    )
                )
            );

        if v_token_hash !~ '^[0-9a-f]{64}$' then
            raise exception 'INVALID_SLOT_TOKEN_HASH';
        end if;


        begin
            v_start_at :=
                (v_slot ->> 'start_at_utc')::timestamptz;

            v_end_at :=
                (v_slot ->> 'end_at_utc')::timestamptz;
        exception
            when others then
                raise exception 'INVALID_SLOT_DATETIME';
        end;


        v_timezone :=
            btrim(
                coalesce(
                    v_slot ->> 'attendee_timezone',
                    ''
                )
            );

        if v_timezone = '' then
            raise exception 'INVALID_SLOT_TIMEZONE';
        end if;

        if v_timezone <> p_requested_timezone then
            raise exception 'SLOT_TIMEZONE_MISMATCH';
        end if;

        if v_end_at <= v_start_at then
            raise exception 'INVALID_SLOT_TIME_ORDER';
        end if;

        if v_start_at < p_window_start_utc
           or v_end_at > p_window_end_utc then
            raise exception 'SLOT_OUTSIDE_REQUEST_WINDOW';
        end if;


        insert into public.booking_request_slots (
            booking_request_id,
            slot_token_hash,
            start_at_utc,
            end_at_utc,
            attendee_timezone,
            status,
            expires_at
        )
        values (
            v_booking_request_id,
            v_token_hash,
            v_start_at,
            v_end_at,
            v_timezone,
            'AVAILABLE',
            p_expires_at
        );

        v_slot_count := v_slot_count + 1;
    end loop;


    return query
    select
        v_booking_request_id,
        v_slot_count;
end;
$$;


-- ============================================================================
-- 4. ACCESS CONTROL
-- Backend service role only.
-- ============================================================================

alter table public.booking_requests
    enable row level security;

alter table public.booking_request_slots
    enable row level security;

revoke all
on table public.booking_requests
from anon, authenticated;

revoke all
on table public.booking_request_slots
from anon, authenticated;

grant select, insert, update, delete
on table public.booking_requests
to service_role;

grant select, insert, update, delete
on table public.booking_request_slots
to service_role;

revoke all
on function public.persist_booking_availability_v1(
    uuid,
    uuid,
    uuid,
    text,
    text,
    text,
    timestamptz,
    timestamptz,
    text,
    timestamptz,
    jsonb
)
from public, anon, authenticated;

grant execute
on function public.persist_booking_availability_v1(
    uuid,
    uuid,
    uuid,
    text,
    text,
    text,
    timestamptz,
    timestamptz,
    text,
    timestamptz,
    jsonb
)
to service_role;

commit;