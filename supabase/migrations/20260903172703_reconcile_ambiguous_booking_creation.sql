-- ============================================================================
-- Migration 007: Reconcile Ambiguous Provider Booking Creation
--
-- A provider booking may succeed even when the synchronous POST response is
-- lost or times out. This RPC safely reconciles a booking that was previously
-- marked CREATE_FAILED / CREATE_OUTCOME_AMBIGUOUS after provider truth has
-- been independently verified.
-- ============================================================================

begin;

create or replace function public.reconcile_ambiguous_booking_creation_v1(
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
    appointment_id uuid,
    booking_request_id text,
    opportunity_id uuid,
    provider_booking_uid text,
    start_at_utc timestamptz,
    end_at_utc timestamptz,
    error_code text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_appointment public.appointments%rowtype;
    v_request_id uuid;
    v_booking_slot_id uuid;
    v_lifecycle_state text;
begin
    if p_provider_booking_uid is null
       or btrim(p_provider_booking_uid) = '' then

        return query
        select
            'ERROR'::text,
            p_appointment_id,
            null::text,
            null::uuid,
            null::text,
            null::timestamptz,
            null::timestamptz,
            'INVALID_PROVIDER_BOOKING_UID'::text;

        return;
    end if;


    if p_provider_start_at is null
       or p_provider_end_at is null
       or p_provider_end_at <= p_provider_start_at then

        return query
        select
            'ERROR'::text,
            p_appointment_id,
            null::text,
            null::uuid,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'INVALID_PROVIDER_BOOKING_TIME'::text;

        return;
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
            p_appointment_id,
            null::text,
            null::uuid,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'APPOINTMENT_NOT_FOUND'::text;

        return;
    end if;


    -- Idempotent reconciliation replay.

    if v_appointment.status = 'CONFIRMED' then
        if v_appointment.booking_uid = p_provider_booking_uid then
            return query
            select
                'ALREADY_RECONCILED'::text,
                v_appointment.appointment_id,
                v_appointment.booking_request_id,
                v_appointment.opportunity_id,
                v_appointment.booking_uid,
                v_appointment.start_at_utc,
                v_appointment.end_at_utc,
                null::text;

            return;
        end if;


        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            v_appointment.booking_uid,
            v_appointment.start_at_utc,
            v_appointment.end_at_utc,
            'PROVIDER_BOOKING_UID_CONFLICT'::text;

        return;
    end if;


    -- Only the explicitly ambiguous provider-create failure may be recovered.

    if v_appointment.status <> 'CREATE_FAILED'
       or v_appointment.provider_status <> 'CREATE_OUTCOME_AMBIGUOUS' then

        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            v_appointment.booking_uid,
            v_appointment.start_at_utc,
            v_appointment.end_at_utc,
            'APPOINTMENT_NOT_AMBIGUOUS_CREATE'::text;

        return;
    end if;


    if v_appointment.booking_uid is not null then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            v_appointment.booking_uid,
            v_appointment.start_at_utc,
            v_appointment.end_at_utc,
            'LOCAL_BOOKING_UID_ALREADY_PRESENT'::text;

        return;
    end if;


    -- Provider result must correspond to the exact slot that was claimed.

    if v_appointment.start_at_utc is distinct from p_provider_start_at
       or v_appointment.end_at_utc is distinct from p_provider_end_at then

        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'PROVIDER_BOOKING_TIME_MISMATCH'::text;

        return;
    end if;


    if v_appointment.booking_request_id is null then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            null::text,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'MISSING_BOOKING_REQUEST_ID'::text;

        return;
    end if;


    begin
        v_request_id =
            v_appointment.booking_request_id::uuid;
    exception
        when others then
            return query
            select
                'ERROR'::text,
                v_appointment.appointment_id,
                v_appointment.booking_request_id,
                v_appointment.opportunity_id,
                p_provider_booking_uid,
                p_provider_start_at,
                p_provider_end_at,
                'INVALID_BOOKING_REQUEST_ID'::text;

            return;
    end;


    perform 1
    from public.booking_requests br
    where br.booking_request_id = v_request_id
      and br.prospect_id = v_appointment.prospect_id
      and br.opportunity_id = v_appointment.opportunity_id
    for update;


    if not found then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'BOOKING_REQUEST_NOT_FOUND'::text;

        return;
    end if;


    if v_appointment.booking_metadata->>'booking_slot_id' is null then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'BOOKING_SLOT_ID_MISSING'::text;

        return;
    end if;


    begin
        v_booking_slot_id =
            (
                v_appointment.booking_metadata
                ->> 'booking_slot_id'
            )::uuid;
    exception
        when others then
            return query
            select
                'ERROR'::text,
                v_appointment.appointment_id,
                v_appointment.booking_request_id,
                v_appointment.opportunity_id,
                p_provider_booking_uid,
                p_provider_start_at,
                p_provider_end_at,
                'INVALID_BOOKING_SLOT_ID'::text;

            return;
    end;


    perform 1
    from public.booking_request_slots brs
    where brs.booking_slot_id = v_booking_slot_id
      and brs.booking_request_id = v_request_id;


    if not found then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'BOOKING_SLOT_NOT_FOUND'::text;

        return;
    end if;


    -- Prevent one provider booking UID being attached to two local bookings.

    perform 1
    from public.appointments a
    where a.booking_uid = p_provider_booking_uid
      and a.appointment_id <> p_appointment_id;


    if found then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'PROVIDER_BOOKING_UID_CONFLICT'::text;

        return;
    end if;


    select o.lifecycle_state
    into v_lifecycle_state
    from public.opportunities o
    where o.opportunity_id = v_appointment.opportunity_id
      and o.prospect_id = v_appointment.prospect_id
    for update;


    if not found then
        return query
        select
            'ERROR'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            'OPPORTUNITY_NOT_FOUND'::text;

        return;
    end if;


    -- Provider truth exists. Restore the local booking state.

    update public.appointments a
    set
        booking_uid = p_provider_booking_uid,

        status = 'CONFIRMED',

        provider_status =
            coalesce(
                nullif(
                    btrim(
                        coalesce(
                            p_provider_status,
                            ''
                        )
                    ),
                    ''
                ),
                'accepted'
            ),

        start_at_utc = p_provider_start_at,
        end_at_utc = p_provider_end_at,

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

                    'reconciled_from_ambiguous_create',
                    true,

                    'reconciled_at',
                    now()
                )
            )

    where a.appointment_id = p_appointment_id;


    update public.booking_requests br
    set status = 'BOOKED'
    where br.booking_request_id = v_request_id;


    -- fail_booking_creation_v1 previously invalidated every offered slot.
    -- Restore only the provider-confirmed selected slot to CONSUMED.

    update public.booking_request_slots brs
    set status =
        case
            when brs.booking_slot_id = v_booking_slot_id
                then 'CONSUMED'
            else 'INVALIDATED'
        end
    where brs.booking_request_id = v_request_id;


    if v_lifecycle_state = 'BOOKING_READY' then
        update public.opportunities o
        set
            lifecycle_state = 'BOOKED',
            last_activity_at = now()
        where o.opportunity_id = v_appointment.opportunity_id;


        return query
        select
            'RECONCILED'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            null::text;

        return;
    end if;


    if v_lifecycle_state = 'BOOKED' then
        return query
        select
            'RECONCILED'::text,
            v_appointment.appointment_id,
            v_appointment.booking_request_id,
            v_appointment.opportunity_id,
            p_provider_booking_uid,
            p_provider_start_at,
            p_provider_end_at,
            null::text;

        return;
    end if;


    -- Provider truth is still persisted, but another lifecycle mutation
    -- requires human review rather than overwriting the new business state.

    return query
    select
        'RECONCILED_REVIEW_REQUIRED'::text,
        v_appointment.appointment_id,
        v_appointment.booking_request_id,
        v_appointment.opportunity_id,
        p_provider_booking_uid,
        p_provider_start_at,
        p_provider_end_at,
        'OPPORTUNITY_STATE_CHANGED_AFTER_PROVIDER_BOOKING'::text;
end;
$$;


revoke all
on function public.reconcile_ambiguous_booking_creation_v1(
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
on function public.reconcile_ambiguous_booking_creation_v1(
    uuid,
    text,
    text,
    timestamptz,
    timestamptz,
    text,
    text
)
to service_role;


commit;