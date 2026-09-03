-- ============================================================================
-- AI Lead Recovery & Appointment Booking System
-- Migration 006: Atomic Booking Creation
--
-- Purpose:
-- - Validate an opaque slot token against server-side availability state.
-- - Resolve attendee identity/contact from authoritative Supabase records.
-- - Atomically claim exactly one booking operation before provider creation.
-- - Finalize provider-confirmed bookings without duplicate creation.
-- - Preserve ambiguous/failed provider outcomes for human review.
-- ============================================================================

begin;


-- ============================================================================
-- 1. CLAIM BOOKING CREATION
--
-- This function performs the final deterministic gate immediately before
-- create_appointment_v1 is allowed to call Cal.com.
--
-- Important:
-- - booking_request_id + slot_token_hash are server validated.
-- - attendee identity is resolved from prospects/contact_points.
-- - an appointments row in CREATE_PENDING state becomes the domain-level
--   duplicate guard before any provider-side booking creation.
-- ============================================================================

create or replace function public.claim_booking_creation_v1(
    p_canonical_call_id uuid,
    p_prospect_id uuid,
    p_opportunity_id uuid,
    p_booking_request_id uuid,
    p_slot_token_hash text
)
returns table (
    result_status text,
    appointment_id uuid,
    provider_booking_uid text,
    provider_event_type_id text,
    start_at_utc timestamptz,
    end_at_utc timestamptz,
    attendee_timezone text,
    attendee_name text,
    attendee_email text,
    error_code text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_request public.booking_requests%rowtype;
    v_slot public.booking_request_slots%rowtype;
    v_existing public.appointments%rowtype;

    v_lifecycle_state text;

    v_attendee_name text;
    v_attendee_email text;

    v_appointment_id uuid;
begin
    if p_canonical_call_id is null
       or p_prospect_id is null
       or p_opportunity_id is null
       or p_booking_request_id is null then

        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            null::text,
            null::timestamptz,
            null::timestamptz,
            null::text,
            null::text,
            null::text,
            'BOOKING_CONTEXT_UNRESOLVED'::text;

        return;
    end if;


    if p_slot_token_hash is null
       or p_slot_token_hash !~ '^[0-9a-f]{64}$' then

        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            null::text,
            null::timestamptz,
            null::timestamptz,
            null::text,
            null::text,
            null::text,
            'INVALID_SLOT_TOKEN'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Lock the booking request.
    -- ------------------------------------------------------------------------

    select br.*
    into v_request
    from public.booking_requests br
    where br.booking_request_id = p_booking_request_id
    for update;


    if not found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            null::text,
            null::timestamptz,
            null::timestamptz,
            null::text,
            null::text,
            null::text,
            'BOOKING_REQUEST_NOT_FOUND'::text;

        return;
    end if;


    if v_request.canonical_call_id <> p_canonical_call_id
       or v_request.prospect_id <> p_prospect_id
       or v_request.opportunity_id <> p_opportunity_id then

        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            null::text,
            null::timestamptz,
            null::timestamptz,
            null::text,
            null::text,
            null::text,
            'BOOKING_REQUEST_CONTEXT_MISMATCH'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- A completed booking is replay-safe.
    -- ------------------------------------------------------------------------

    if v_request.status = 'BOOKED' then
        select a.*
        into v_existing
        from public.appointments a
        where a.booking_request_id = p_booking_request_id::text
          and a.status = 'CONFIRMED'
        limit 1;


        if found then
            return query
            select
                'ALREADY_BOOKED'::text,
                v_existing.appointment_id,
                v_existing.booking_uid,
                v_existing.provider_event_type_id,
                v_existing.start_at_utc,
                v_existing.end_at_utc,
                v_existing.attendee_timezone,
                null::text,
                null::text,
                null::text;

            return;
        end if;


        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            null::timestamptz,
            null::timestamptz,
            v_request.requested_timezone,
            null::text,
            null::text,
            'BOOKING_STATE_INCONSISTENT'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Expired availability can never be booked.
    -- ------------------------------------------------------------------------

    if v_request.expires_at <= now() then
        update public.booking_requests br
        set status = 'EXPIRED'
        where br.booking_request_id = p_booking_request_id;


        update public.booking_request_slots brs
        set status = 'EXPIRED'
        where brs.booking_request_id = p_booking_request_id
          and brs.status in (
              'AVAILABLE',
              'SELECTED'
          );


        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            null::timestamptz,
            null::timestamptz,
            v_request.requested_timezone,
            null::text,
            null::text,
            'BOOKING_REQUEST_EXPIRED'::text;

        return;
    end if;


    if v_request.status not in (
        'AVAILABILITY_REQUESTED',
        'SLOT_SELECTED'
    ) then

        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            null::timestamptz,
            null::timestamptz,
            v_request.requested_timezone,
            null::text,
            null::text,
            'BOOKING_OPERATION_ALREADY_STARTED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Recheck opportunity state under lock.
    -- ------------------------------------------------------------------------

    select o.lifecycle_state
    into v_lifecycle_state
    from public.opportunities o
    where o.opportunity_id = p_opportunity_id
      and o.prospect_id = p_prospect_id
    for update;


    if not found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            null::timestamptz,
            null::timestamptz,
            v_request.requested_timezone,
            null::text,
            null::text,
            'BOOKING_CONTEXT_UNRESOLVED'::text;

        return;
    end if;


    if v_lifecycle_state <> 'BOOKING_READY' then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            null::timestamptz,
            null::timestamptz,
            v_request.requested_timezone,
            null::text,
            null::text,
            'OPPORTUNITY_NOT_BOOKING_READY'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Validate the opaque slot token against its stored hash.
    -- ------------------------------------------------------------------------

    select brs.*
    into v_slot
    from public.booking_request_slots brs
    where brs.booking_request_id = p_booking_request_id
      and brs.slot_token_hash = p_slot_token_hash
    for update;


    if not found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            null::timestamptz,
            null::timestamptz,
            v_request.requested_timezone,
            null::text,
            null::text,
            'INVALID_SLOT_TOKEN'::text;

        return;
    end if;


    if v_slot.expires_at <= now() then
        update public.booking_request_slots brs
        set status = 'EXPIRED'
        where brs.booking_slot_id = v_slot.booking_slot_id;


        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            v_slot.start_at_utc,
            v_slot.end_at_utc,
            v_slot.attendee_timezone,
            null::text,
            null::text,
            'SLOT_TOKEN_EXPIRED'::text;

        return;
    end if;


    if v_slot.status not in (
        'AVAILABLE',
        'SELECTED'
    ) then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            v_slot.start_at_utc,
            v_slot.end_at_utc,
            v_slot.attendee_timezone,
            null::text,
            null::text,
            'SLOT_NOT_BOOKABLE'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Domain-level duplicate guard.
    -- ------------------------------------------------------------------------

    select a.*
    into v_existing
    from public.appointments a
    where a.opportunity_id = p_opportunity_id
      and a.status in (
          'CREATE_PENDING',
          'CONFIRMED',
          'RESCHEDULE_PENDING'
      )
    order by a.created_at
    limit 1
    for update;


    if found then
        if v_existing.booking_request_id = p_booking_request_id::text
           and v_existing.status = 'CONFIRMED' then

            return query
            select
                'ALREADY_BOOKED'::text,
                v_existing.appointment_id,
                v_existing.booking_uid,
                v_existing.provider_event_type_id,
                v_existing.start_at_utc,
                v_existing.end_at_utc,
                v_existing.attendee_timezone,
                null::text,
                null::text,
                null::text;

            return;
        end if;


        return query
        select
            'HUMAN_REQUIRED'::text,
            v_existing.appointment_id,
            v_existing.booking_uid,
            v_existing.provider_event_type_id,
            v_existing.start_at_utc,
            v_existing.end_at_utc,
            v_existing.attendee_timezone,
            null::text,
            null::text,
            'ACTIVE_APPOINTMENT_EXISTS'::text;

        return;
    end if;


    -- Also block a previous non-active operation for the same request.
    -- We never blindly retry a provider create after an ambiguous failure.

    select a.*
    into v_existing
    from public.appointments a
    where a.booking_request_id = p_booking_request_id::text
    order by a.created_at
    limit 1
    for update;


    if found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            v_existing.appointment_id,
            v_existing.booking_uid,
            v_existing.provider_event_type_id,
            v_existing.start_at_utc,
            v_existing.end_at_utc,
            v_existing.attendee_timezone,
            null::text,
            null::text,
            'BOOKING_OPERATION_ALREADY_STARTED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Resolve attendee name from canonical prospect identity.
    -- ------------------------------------------------------------------------

    select
        nullif(
            btrim(
                concat_ws(
                    ' ',
                    nullif(btrim(p.first_name), ''),
                    nullif(btrim(p.last_name), '')
                )
            ),
            ''
        )
    into v_attendee_name
    from public.prospects p
    where p.prospect_id = p_prospect_id
      and p.identity_status <> 'MERGED';


    if v_attendee_name is null then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            v_slot.start_at_utc,
            v_slot.end_at_utc,
            v_slot.attendee_timezone,
            null::text,
            null::text,
            'MISSING_BOOKING_NAME'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Resolve deterministic booking email.
    --
    -- Prefer:
    -- 1. primary email
    -- 2. verified email
    -- 3. earliest otherwise-usable email
    --
    -- INVALID and REVIEW_REQUIRED contact points are never used for booking.
    -- ------------------------------------------------------------------------

    select cp.normalized_value
    into v_attendee_email
    from public.contact_points cp
    where cp.prospect_id = p_prospect_id
      and cp.contact_type = 'EMAIL'
      and cp.verification_state in (
          'VERIFIED',
          'UNVERIFIED'
      )
      and length(btrim(cp.normalized_value)) > 0
    order by
        cp.is_primary desc,
        case
            when cp.verification_state = 'VERIFIED' then 0
            else 1
        end,
        cp.created_at
    limit 1;


    if v_attendee_email is null then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::uuid,
            null::text,
            v_request.provider_event_type_id,
            v_slot.start_at_utc,
            v_slot.end_at_utc,
            v_slot.attendee_timezone,
            v_attendee_name,
            null::text,
            'MISSING_BOOKING_EMAIL'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Claim the booking operation.
    -- ------------------------------------------------------------------------

    update public.booking_requests br
    set status = 'BOOKING_PENDING'
    where br.booking_request_id = p_booking_request_id;


    update public.booking_request_slots brs
    set status = 'SELECTED'
    where brs.booking_slot_id = v_slot.booking_slot_id;


    insert into public.appointments (
        prospect_id,
        opportunity_id,
        provider,
        booking_request_id,
        event_type_code,
        provider_event_type_id,
        start_at_utc,
        end_at_utc,
        attendee_timezone,
        status,
        provider_status,
        booking_metadata
    )
    values (
        p_prospect_id,
        p_opportunity_id,
        'CAL_COM',
        p_booking_request_id::text,
        v_request.event_type_code,
        v_request.provider_event_type_id,
        v_slot.start_at_utc,
        v_slot.end_at_utc,
        v_slot.attendee_timezone,
        'CREATE_PENDING',
        'CREATE_PENDING',
        jsonb_build_object(
            'booking_slot_id',
            v_slot.booking_slot_id::text
        )
    )
    returning appointments.appointment_id
    into v_appointment_id;


    return query
    select
        'CLAIMED'::text,
        v_appointment_id,
        null::text,
        v_request.provider_event_type_id,
        v_slot.start_at_utc,
        v_slot.end_at_utc,
        v_slot.attendee_timezone,
        v_attendee_name,
        v_attendee_email,
        null::text;
end;
$$;


-- ============================================================================
-- 2. FINALIZE PROVIDER-CONFIRMED BOOKING
--
-- Cal.com has already created a real booking when this function is called.
-- Therefore provider truth must always be persisted, even if another internal
-- lifecycle change occurred during the network request.
-- ============================================================================

create or replace function public.finalize_booking_creation_v1(
    p_appointment_id uuid,
    p_provider_booking_uid text,
    p_provider_booking_id text,
    p_provider_start_at timestamptz,
    p_provider_end_at timestamptz,
    p_provider_status text,
    p_meeting_url text
)
returns table (
    result_status text,
    booking_request_id text,
    opportunity_id uuid,
    provider_booking_uid text,
    start_at_utc timestamptz,
    end_at_utc timestamptz,
    provider_time_mismatch boolean,
    error_code text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_appointment public.appointments%rowtype;
    v_request_id uuid;

    v_lifecycle_state text;
    v_time_mismatch boolean;
begin
    if p_provider_booking_uid is null
       or btrim(p_provider_booking_uid) = '' then
        raise exception 'INVALID_PROVIDER_BOOKING_UID';
    end if;


    if p_provider_start_at is null
       or p_provider_end_at is null
       or p_provider_end_at <= p_provider_start_at then
        raise exception 'INVALID_PROVIDER_BOOKING_TIME';
    end if;


    select a.*
    into v_appointment
    from public.appointments a
    where a.appointment_id = p_appointment_id
    for update;


    if not found then
        return query
        select
            'ERROR'::text,
            null::text,
            null::uuid,
            null::text,
            null::timestamptz,
            null::timestamptz,
            false,
            'APPOINTMENT_NOT_FOUND'::text;

        return;
    end if;


    if v_appointment.status = 'CONFIRMED' then
        if v_appointment.booking_uid = p_provider_booking_uid then
            return query
            select
                'ALREADY_BOOKED'::text,
                v_appointment.booking_request_id,
                v_appointment.opportunity_id,
                v_appointment.booking_uid,
                v_appointment.start_at_utc,
                v_appointment.end_at_utc,
                false,
                null::text;

            return;
        end if;


        return query
        select
            'ERROR'::text,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            v_appointment.booking_uid,
            v_appointment.start_at_utc,
            v_appointment.end_at_utc,
            false,
            'PROVIDER_BOOKING_UID_CONFLICT'::text;

        return;
    end if;


    if v_appointment.status <> 'CREATE_PENDING' then
        return query
        select
            'ERROR'::text,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            v_appointment.booking_uid,
            v_appointment.start_at_utc,
            v_appointment.end_at_utc,
            false,
            'APPOINTMENT_NOT_CREATE_PENDING'::text;

        return;
    end if;


    if v_appointment.booking_request_id is null then
        raise exception 'MISSING_BOOKING_REQUEST_ID';
    end if;


    begin
        v_request_id :=
            v_appointment.booking_request_id::uuid;
    exception
        when others then
            raise exception 'INVALID_BOOKING_REQUEST_ID';
    end;


    perform 1
    from public.booking_requests br
    where br.booking_request_id = v_request_id
      and br.opportunity_id = v_appointment.opportunity_id
      and br.prospect_id = v_appointment.prospect_id
    for update;


    if not found then
        raise exception 'BOOKING_REQUEST_NOT_FOUND';
    end if;


    select o.lifecycle_state
    into v_lifecycle_state
    from public.opportunities o
    where o.opportunity_id = v_appointment.opportunity_id
      and o.prospect_id = v_appointment.prospect_id
    for update;


    if not found then
        raise exception 'OPPORTUNITY_NOT_FOUND';
    end if;


    v_time_mismatch :=
        v_appointment.start_at_utc is distinct from p_provider_start_at
        or
        v_appointment.end_at_utc is distinct from p_provider_end_at;


    -- Provider booking truth now exists. Persist it first.

    update public.appointments a
    set
        booking_uid = p_provider_booking_uid,
        start_at_utc = p_provider_start_at,
        end_at_utc = p_provider_end_at,
        status = 'CONFIRMED',
        provider_status = nullif(
            btrim(
                coalesce(
                    p_provider_status,
                    ''
                )
            ),
            ''
        ),
        booking_metadata =
            a.booking_metadata ||
            jsonb_strip_nulls(
                jsonb_build_object(
                    'provider_booking_id',
                    nullif(
                        btrim(
                            coalesce(
                                p_provider_booking_id,
                                ''
                            )
                        ),
                        ''
                    ),
                    'meeting_url',
                    nullif(
                        btrim(
                            coalesce(
                                p_meeting_url,
                                ''
                            )
                        ),
                        ''
                    ),
                    'provider_time_mismatch',
                    v_time_mismatch
                )
            )
    where a.appointment_id = p_appointment_id;


    update public.booking_requests br
    set status = 'BOOKED'
    where br.booking_request_id = v_request_id;


    update public.booking_request_slots brs
    set status =
        case
            when brs.status = 'SELECTED'
                then 'CONSUMED'
            else 'INVALIDATED'
        end
    where brs.booking_request_id = v_request_id
      and brs.status in (
          'AVAILABLE',
          'SELECTED'
      );


    -- Only the expected lifecycle transition is automatic.
    -- If another process changed the opportunity during the provider call,
    -- retain provider booking truth but flag the lifecycle for human review.

    if v_lifecycle_state = 'BOOKING_READY' then
        update public.opportunities o
        set
            lifecycle_state = 'BOOKED',
            last_activity_at = now()
        where o.opportunity_id = v_appointment.opportunity_id;


        return query
        select
            'CONFIRMED'::text,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            v_time_mismatch,
            null::text;

        return;
    end if;


    if v_lifecycle_state = 'BOOKED' then
        return query
        select
            'CONFIRMED'::text,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            v_time_mismatch,
            null::text;

        return;
    end if;


    return query
    select
        'CONFIRMED_REVIEW_REQUIRED'::text,
        v_appointment.booking_request_id,
        v_appointment.opportunity_id,
        p_provider_booking_uid,
        p_provider_start_at,
        p_provider_end_at,
        v_time_mismatch,
        'OPPORTUNITY_STATE_CHANGED_AFTER_PROVIDER_BOOKING'::text;
end;
$$;


-- ============================================================================
-- 3. MARK BOOKING CREATION FAILED
--
-- Any started provider create operation is retained as a failed appointment.
-- create_appointment_v1 must never blindly call the provider again for the
-- same booking_request_id after this state exists.
-- ============================================================================

create or replace function public.fail_booking_creation_v1(
    p_appointment_id uuid,
    p_error_code text,
    p_provider_status text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_appointment public.appointments%rowtype;
    v_request_id uuid;
begin
    select a.*
    into v_appointment
    from public.appointments a
    where a.appointment_id = p_appointment_id
    for update;


    if not found then
        return false;
    end if;


    -- Never downgrade a provider-confirmed booking.

    if v_appointment.status = 'CONFIRMED' then
        return false;
    end if;


    if v_appointment.status <> 'CREATE_PENDING' then
        return true;
    end if;


    update public.appointments a
    set
        status = 'CREATE_FAILED',
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
        booking_metadata =
            a.booking_metadata ||
            jsonb_build_object(
                'create_error_code',
                coalesce(
                    nullif(
                        btrim(
                            p_error_code
                        ),
                        ''
                    ),
                    'UNKNOWN'
                )
            )
    where a.appointment_id = p_appointment_id;


    if v_appointment.booking_request_id is not null then
        begin
            v_request_id :=
                v_appointment.booking_request_id::uuid;


            update public.booking_requests br
            set status = 'FAILED'
            where br.booking_request_id = v_request_id
              and br.status <> 'BOOKED';


            update public.booking_request_slots brs
            set status = 'INVALIDATED'
            where brs.booking_request_id = v_request_id
              and brs.status in (
                  'AVAILABLE',
                  'SELECTED'
              );

        exception
            when others then
                null;
        end;
    end if;


    return true;
end;
$$;


-- ============================================================================
-- 4. SECURITY
-- Service-role backend only.
-- ============================================================================

revoke all
on function public.claim_booking_creation_v1(
    uuid,
    uuid,
    uuid,
    uuid,
    text
)
from public, anon, authenticated;

grant execute
on function public.claim_booking_creation_v1(
    uuid,
    uuid,
    uuid,
    uuid,
    text
)
to service_role;


revoke all
on function public.finalize_booking_creation_v1(
    uuid,
    text,
    text,
    timestamptz,
    timestamptz,
    text,
    text
)
from public, anon, authenticated;

grant execute
on function public.finalize_booking_creation_v1(
    uuid,
    text,
    text,
    timestamptz,
    timestamptz,
    text,
    text
)
to service_role;


revoke all
on function public.fail_booking_creation_v1(
    uuid,
    text,
    text
)
from public, anon, authenticated;

grant execute
on function public.fail_booking_creation_v1(
    uuid,
    text,
    text
)
to service_role;


commit;