-- ============================================================================
-- Migration 008: Deterministic Booking Readiness
--
-- Purpose:
-- Convert a safely resolved Meridian demo enquiry into BOOKING_READY using
-- backend-controlled deterministic rules. Retell never sets lifecycle or
-- qualification state directly.
--
-- For this demo, booking qualification means:
-- - canonical call/prospect/opportunity context is consistent;
-- - prospect has not been merged;
-- - enquiry intent is known;
-- - opportunity is not disqualified/review-required/terminal;
-- - a usable canonical email exists;
-- - no active appointment already exists.
-- ============================================================================

begin;


create or replace function public.prepare_booking_readiness_v1(
    p_canonical_call_id uuid,
    p_prospect_id uuid,
    p_opportunity_id uuid
)
returns table (
    result_status text,
    current_lifecycle_state text,
    current_qualification_state text,
    error_code text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_lifecycle_state text;
    v_qualification_state text;
    v_lead_type text;
    v_current_intent text;
    v_merged_into_prospect_id uuid;
begin

    -- ------------------------------------------------------------------------
    -- Required canonical context.
    -- ------------------------------------------------------------------------

    if p_canonical_call_id is null
       or p_prospect_id is null
       or p_opportunity_id is null then

        return query
        select
            'HUMAN_REQUIRED'::text,
            null::text,
            null::text,
            'BOOKING_CONTEXT_UNRESOLVED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Canonical call must belong to the same prospect/opportunity.
    -- ------------------------------------------------------------------------

    perform 1
    from public.calls c
    where c.call_id = p_canonical_call_id
      and c.prospect_id = p_prospect_id
      and c.opportunity_id = p_opportunity_id;


    if not found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::text,
            null::text,
            'BOOKING_CONTEXT_MISMATCH'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Prospect must still be the canonical identity.
    -- ------------------------------------------------------------------------

    select
        p.merged_into_prospect_id
    into
        v_merged_into_prospect_id
    from public.prospects p
    where p.prospect_id = p_prospect_id;


    if not found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::text,
            null::text,
            'PROSPECT_NOT_FOUND'::text;

        return;
    end if;


    if v_merged_into_prospect_id is not null then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::text,
            null::text,
            'PROSPECT_IDENTITY_CHANGED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Lock and inspect the opportunity.
    -- ------------------------------------------------------------------------

    select
        o.lifecycle_state,
        o.qualification_state,
        o.lead_type,
        o.current_intent
    into
        v_lifecycle_state,
        v_qualification_state,
        v_lead_type,
        v_current_intent
    from public.opportunities o
    where o.opportunity_id = p_opportunity_id
      and o.prospect_id = p_prospect_id
    for update;


    if not found then
        return query
        select
            'HUMAN_REQUIRED'::text,
            null::text,
            null::text,
            'OPPORTUNITY_NOT_FOUND'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Idempotent success.
    -- ------------------------------------------------------------------------

    if v_lifecycle_state = 'BOOKING_READY'
       and v_qualification_state = 'QUALIFIED' then

        return query
        select
            'ALREADY_READY'::text,
            v_lifecycle_state,
            v_qualification_state,
            null::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Existing booking cannot be reopened.
    -- ------------------------------------------------------------------------

    if v_lifecycle_state = 'BOOKED' then

        return query
        select
            'NOT_ELIGIBLE'::text,
            v_lifecycle_state,
            v_qualification_state,
            'ALREADY_BOOKED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Terminal or dormant opportunities require human/business handling.
    -- ------------------------------------------------------------------------

    if v_lifecycle_state in (
        'DORMANT',
        'WON',
        'LOST',
        'CLOSED'
    ) then

        return query
        select
            'NOT_ELIGIBLE'::text,
            v_lifecycle_state,
            v_qualification_state,
            'OPPORTUNITY_NOT_ACTIVE'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Never override prior review/disqualification decisions.
    -- ------------------------------------------------------------------------

    if v_qualification_state = 'REVIEW_REQUIRED' then

        return query
        select
            'HUMAN_REQUIRED'::text,
            v_lifecycle_state,
            v_qualification_state,
            'QUALIFICATION_REVIEW_REQUIRED'::text;

        return;
    end if;


    if v_qualification_state = 'DISQUALIFIED' then

        return query
        select
            'NOT_ELIGIBLE'::text,
            v_lifecycle_state,
            v_qualification_state,
            'OPPORTUNITY_DISQUALIFIED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- The business enquiry must already be deterministically classified.
    -- ------------------------------------------------------------------------

    if v_lead_type = 'UNKNOWN'
       or v_current_intent = 'UNKNOWN' then

        return query
        select
            'HUMAN_REQUIRED'::text,
            v_lifecycle_state,
            v_qualification_state,
            'ENQUIRY_NOT_CLASSIFIED'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Cal.com booking requires a usable canonical email.
    -- Do not accept INVALID or REVIEW_REQUIRED contact points.
    -- ------------------------------------------------------------------------

    perform 1
    from public.contact_points cp
    where cp.prospect_id = p_prospect_id
      and cp.contact_type = 'EMAIL'
      and cp.verification_state in (
          'VERIFIED',
          'UNVERIFIED'
      )
      and length(btrim(cp.normalized_value)) > 0;


    if not found then

        return query
        select
            'HUMAN_REQUIRED'::text,
            v_lifecycle_state,
            v_qualification_state,
            'MISSING_BOOKING_EMAIL'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- A separate active appointment blocks another booking.
    -- ------------------------------------------------------------------------

    perform 1
    from public.appointments a
    where a.opportunity_id = p_opportunity_id
      and a.status in (
          'CREATE_PENDING',
          'CONFIRMED',
          'RESCHEDULE_PENDING'
      );


    if found then

        return query
        select
            'NOT_ELIGIBLE'::text,
            v_lifecycle_state,
            v_qualification_state,
            'ACTIVE_APPOINTMENT_EXISTS'::text;

        return;
    end if;


    -- ------------------------------------------------------------------------
    -- Only active pre-booking lifecycle states may advance.
    --
    -- Intermediate states are not invented by Retell. This function performs
    -- one authoritative atomic transition after all deterministic checks pass.
    -- ------------------------------------------------------------------------

    if v_lifecycle_state not in (
        'NEW',
        'ENGAGED',
        'QUALIFYING',
        'QUALIFIED'
    ) then

        return query
        select
            'HUMAN_REQUIRED'::text,
            v_lifecycle_state,
            v_qualification_state,
            'OPPORTUNITY_STATE_CONFLICT'::text;

        return;
    end if;


    update public.opportunities o
    set
        qualification_state = 'QUALIFIED',
        lifecycle_state = 'BOOKING_READY',
        last_activity_at = now()
    where o.opportunity_id = p_opportunity_id
      and o.prospect_id = p_prospect_id;


    return query
    select
        'READY'::text,
        'BOOKING_READY'::text,
        'QUALIFIED'::text,
        null::text;

end;
$$;


revoke all
on function public.prepare_booking_readiness_v1(
    uuid,
    uuid,
    uuid
)
from public, anon, authenticated;


grant execute
on function public.prepare_booking_readiness_v1(
    uuid,
    uuid,
    uuid
)
to service_role;


commit;