-- ============================================================================
-- Caller email correction + invalid-contact identity hardening
--
-- Purpose:
--   1. Exclude INVALID contact points from future canonical identity matching.
--   2. Add an atomic same-call primary-email correction operation.
--
-- Safety:
--   - canonical call/prospect/opportunity IDs remain server-owned;
--   - a corrected email never reassigns identity across prospects;
--   - conflicting identity/contact state routes to review;
--   - existing booking/provider state is not mutated;
--   - the caller-corrected primary email is retained for audit but marked INVALID;
--   - stale contact-specific eligibility is made INELIGIBLE;
--   - correction is audit logged without duplicating email PII into audit_events.
-- ============================================================================

-- ============================================================================
-- 1. Harden capture identity matching.
--
-- The original resolver treated contact_points with verification_state=INVALID
-- as identity evidence. Once caller corrections can invalidate an email, that
-- would allow a known-invalid address to match the old prospect on a later call.
--
-- The resolver is otherwise unchanged.
-- ============================================================================

create or replace function public.resolve_capture_context_v1(
    p_call_id uuid,

    p_first_name text default null,
    p_last_name text default null,
    p_company_name text default null,

    p_email_raw text default null,
    p_email_normalized text default null,

    p_phone_raw text default null,
    p_phone_normalized text default null,

    p_location_code text default null,
    p_stated_intent text default null
)
returns table (
    status text,
    prospect_id uuid,
    opportunity_id uuid,
    identity_resolution text,
    opportunity_resolution text,
    current_lifecycle_state text,
    error_code text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_call public.calls%rowtype;

    v_candidate_ids uuid[];
    v_candidate_count integer := 0;

    v_prospect_id uuid;
    v_prospect_status text;

    v_opportunity_ids uuid[];
    v_opportunity_count integer := 0;
    v_opportunity_id uuid;
    v_lifecycle_state text;

    v_source_channel text;
    v_source_event_key text;

    v_lead_type text;
    v_location_code text;

    v_identity_resolution text;
begin

    --------------------------------------------------------------------------
    -- Canonical call row is the serialization anchor for this call.
    --------------------------------------------------------------------------

    select *
    into v_call
    from public.calls
    where call_id = p_call_id
    for update;


    if not found then
        return query
        select
            'ERROR'::text,
            null::uuid,
            null::uuid,
            'INSUFFICIENT_IDENTITY'::text,
            'NOT_RESOLVED'::text,
            null::text,
            'CALL_CONTEXT_UNAVAILABLE'::text;

        return;
    end if;


    --------------------------------------------------------------------------
    -- Normalize null/blank semantic inputs.
    --------------------------------------------------------------------------

    p_email_normalized :=
        nullif(
            lower(
                btrim(
                    p_email_normalized
                )
            ),
            ''
        );


    p_phone_normalized :=
        nullif(
            btrim(
                p_phone_normalized
            ),
            ''
        );


    v_lead_type :=
        coalesce(
            nullif(
                btrim(
                    p_stated_intent
                ),
                ''
            ),
            'UNKNOWN'
        );


    if v_lead_type not in (
        'PROFESSIONAL_TRAINING',
        'BUSINESS_PARTNERSHIP',
        'GENERAL_SERVICE',
        'UNKNOWN'
    ) then
        v_lead_type := 'UNKNOWN';
    end if;


    v_location_code :=
        coalesce(
            nullif(
                btrim(
                    p_location_code
                ),
                ''
            ),
            'UNKNOWN'
        );


    if v_location_code not in (
        'BRISBANE',
        'MELBOURNE',
        'SYDNEY',
        'PERTH',
        'OTHER',
        'UNKNOWN'
    ) then
        v_location_code := 'UNKNOWN';
    end if;


    --------------------------------------------------------------------------
    -- Serialize identity operations for the same normalized contact values.
    --
    -- This prevents two simultaneous calls carrying the same new email/phone
    -- from independently deciding that no prospect exists and both creating
    -- separate prospects.
    --------------------------------------------------------------------------

    if p_email_normalized is not null then
        perform pg_advisory_xact_lock(
            hashtextextended(
                'IDENTITY:EMAIL:' ||
                p_email_normalized,
                0
            )
        );
    end if;


    if p_phone_normalized is not null then
        perform pg_advisory_xact_lock(
            hashtextextended(
                'IDENTITY:PHONE:' ||
                p_phone_normalized,
                0
            )
        );
    end if;


    --------------------------------------------------------------------------
    -- Resolve contact evidence.
    --
    -- MERGED records resolve one level to their canonical target rather than
    -- creating another duplicate merely because the old contact point remains.
    --------------------------------------------------------------------------

    if
        p_email_normalized is not null
        or p_phone_normalized is not null
    then

        select array_agg(
            distinct
            case
                when p.identity_status = 'MERGED'
                    then p.merged_into_prospect_id
                else p.prospect_id
            end
        )
        into v_candidate_ids
        from public.contact_points cp
        join public.prospects p
          on p.prospect_id = cp.prospect_id
        where cp.verification_state <> 'INVALID'
          and (
                (
                    p_email_normalized is not null
                    and cp.contact_type = 'EMAIL'
                    and cp.normalized_value = p_email_normalized
                )
                or
                (
                    p_phone_normalized is not null
                    and cp.contact_type = 'PHONE'
                    and cp.normalized_value = p_phone_normalized
                )
          );


        v_candidate_count :=
            coalesce(
                cardinality(
                    v_candidate_ids
                ),
                0
            );

    end if;


    --------------------------------------------------------------------------
    -- If this call already owns canonical prospect context, preserve it unless
    -- newly supplied contact evidence points at another prospect.
    --------------------------------------------------------------------------

    if v_call.prospect_id is not null then

        if v_candidate_count > 1 then
            return query
            select
                'REVIEW_REQUIRED'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                'AMBIGUOUS'::text,
                case
                    when v_call.opportunity_id is null
                        then 'NOT_RESOLVED'
                    else 'EXISTING'
                end::text,
                null::text,
                'IDENTITY_AMBIGUOUS'::text;

            return;
        end if;


        if
            v_candidate_count = 1
            and v_candidate_ids[1] <>
                v_call.prospect_id
        then
            return query
            select
                'REVIEW_REQUIRED'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                'AMBIGUOUS'::text,
                case
                    when v_call.opportunity_id is null
                        then 'NOT_RESOLVED'
                    else 'EXISTING'
                end::text,
                null::text,
                'IDENTITY_AMBIGUOUS'::text;

            return;
        end if;


        v_prospect_id :=
            v_call.prospect_id;

        v_identity_resolution :=
            'EXACT_MATCH';

    else

        ----------------------------------------------------------------------
        -- Unlinked call: identity requires email or phone evidence.
        ----------------------------------------------------------------------

        if
            p_email_normalized is null
            and p_phone_normalized is null
        then
            return query
            select
                'REVIEW_REQUIRED'::text,
                null::uuid,
                null::uuid,
                'INSUFFICIENT_IDENTITY'::text,
                'NOT_RESOLVED'::text,
                null::text,
                'INSUFFICIENT_IDENTITY'::text;

            return;
        end if;


        if v_candidate_count > 1 then
            return query
            select
                'REVIEW_REQUIRED'::text,
                null::uuid,
                null::uuid,
                'AMBIGUOUS'::text,
                'NOT_RESOLVED'::text,
                null::text,
                'IDENTITY_AMBIGUOUS'::text;

            return;
        end if;


        if v_candidate_count = 1 then

            v_prospect_id :=
                v_candidate_ids[1];

            select p_resolved.identity_status
            into v_prospect_status
            from public.prospects as p_resolved
            where p_resolved.prospect_id =
                v_prospect_id;


            if
                v_prospect_status is null
                or
                v_prospect_status <>
                    'ACTIVE'
            then
                return query
                select
                    'REVIEW_REQUIRED'::text,
                    v_prospect_id,
                    null::uuid,
                    'EXACT_MATCH'::text,
                    'NOT_RESOLVED'::text,
                    null::text,
                    'IDENTITY_AMBIGUOUS'::text;

                return;
            end if;


            v_identity_resolution :=
                'EXACT_MATCH';

        else

            ------------------------------------------------------------------
            -- No contact match: create canonical prospect.
            ------------------------------------------------------------------

            insert into public.prospects as p_created (
                first_name,
                last_name,
                company_name,
                primary_location_code,
                identity_status
            )
            values (
                nullif(
                    btrim(
                        p_first_name
                    ),
                    ''
                ),

                nullif(
                    btrim(
                        p_last_name
                    ),
                    ''
                ),

                nullif(
                    btrim(
                        p_company_name
                    ),
                    ''
                ),

                v_location_code,

                'ACTIVE'
            )
            returning p_created.prospect_id
            into v_prospect_id;


            v_identity_resolution :=
                'CREATED';

        end if;

    end if;


    --------------------------------------------------------------------------
    -- Prospect-level serialization protects opportunity resolution from
    -- concurrent calls belonging to the same canonical prospect.
    --------------------------------------------------------------------------

    perform pg_advisory_xact_lock(
        hashtextextended(
            'PROSPECT:' ||
            v_prospect_id::text,
            0
        )
    );


    --------------------------------------------------------------------------
    -- Enrich only missing prospect information.
    --
    -- Never overwrite an already-known name/company/location merely because
    -- the conversational model supplied a different value.
    --------------------------------------------------------------------------

    update public.prospects as p_profile
    set
        first_name =
            case
                when first_name is null
                    then nullif(
                        btrim(
                            p_first_name
                        ),
                        ''
                    )
                else first_name
            end,

        last_name =
            case
                when last_name is null
                    then nullif(
                        btrim(
                            p_last_name
                        ),
                        ''
                    )
                else last_name
            end,

        company_name =
            case
                when company_name is null
                    then nullif(
                        btrim(
                            p_company_name
                        ),
                        ''
                    )
                else company_name
            end,

        primary_location_code =
            case
                when
                    primary_location_code =
                        'UNKNOWN'
                    and
                    v_location_code <>
                        'UNKNOWN'
                then v_location_code

                else
                    primary_location_code
            end

    where p_profile.prospect_id =
        v_prospect_id;


    --------------------------------------------------------------------------
    -- Attach supplied contact points only when the exact normalized identity
    -- is not already present for this prospect.
    --------------------------------------------------------------------------

    if p_email_normalized is not null then

        if not exists (
            select 1
            from public.contact_points as cp_lookup
            where cp_lookup.prospect_id =
                v_prospect_id
              and contact_type =
                'EMAIL'
              and normalized_value =
                p_email_normalized
        ) then

            insert into public.contact_points (
                prospect_id,
                contact_type,
                raw_value,
                normalized_value,
                is_primary,
                verification_state
            )
            values (
                v_prospect_id,
                'EMAIL',
                coalesce(
                    nullif(
                        btrim(
                            p_email_raw
                        ),
                        ''
                    ),
                    p_email_normalized
                ),
                p_email_normalized,

                not exists (
                    select 1
                    from public.contact_points as cp_lookup
                    where cp_lookup.prospect_id =
                        v_prospect_id
                      and contact_type =
                        'EMAIL'
                ),

                'UNVERIFIED'
            );

        end if;

    end if;


    if p_phone_normalized is not null then

        if not exists (
            select 1
            from public.contact_points as cp_lookup
            where cp_lookup.prospect_id =
                v_prospect_id
              and contact_type =
                'PHONE'
              and normalized_value =
                p_phone_normalized
        ) then

            insert into public.contact_points (
                prospect_id,
                contact_type,
                raw_value,
                normalized_value,
                is_primary,
                verification_state
            )
            values (
                v_prospect_id,
                'PHONE',
                coalesce(
                    nullif(
                        btrim(
                            p_phone_raw
                        ),
                        ''
                    ),
                    p_phone_normalized
                ),
                p_phone_normalized,

                not exists (
                    select 1
                    from public.contact_points as cp_lookup
                    where cp_lookup.prospect_id =
                        v_prospect_id
                      and contact_type =
                        'PHONE'
                ),

                'UNVERIFIED'
            );

        end if;

    end if;


    --------------------------------------------------------------------------
    -- Identity is now authoritative enough to attach to the call.
    --------------------------------------------------------------------------

    if v_call.prospect_id is null then
        update public.calls
        set prospect_id =
            v_prospect_id
        where call_id =
            p_call_id;

        v_call.prospect_id :=
            v_prospect_id;
    end if;


    --------------------------------------------------------------------------
    -- Existing call-linked opportunity is authoritative.
    --------------------------------------------------------------------------

    if v_call.opportunity_id is not null then

        select o_linked.lifecycle_state
        into v_lifecycle_state
        from public.opportunities as o_linked
        where o_linked.opportunity_id =
            v_call.opportunity_id
          and o_linked.prospect_id =
            v_prospect_id;


        if not found then
            return query
            select
                'ERROR'::text,
                v_prospect_id,
                null::uuid,
                v_identity_resolution,
                'NOT_RESOLVED'::text,
                null::text,
                'OPPORTUNITY_STATE_CONFLICT'::text;

            return;
        end if;


        return query
        select
            'RESOLVED'::text,
            v_prospect_id,
            v_call.opportunity_id,
            v_identity_resolution,
            'EXISTING'::text,
            v_lifecycle_state,
            null::text;

        return;

    end if;


    --------------------------------------------------------------------------
    -- Resolve one compatible active opportunity.
    --
    -- We do not choose between multiple compatible live opportunities.
    --------------------------------------------------------------------------

    select array_agg(
        o_active.opportunity_id
        order by o_active.created_at desc
    )
    into v_opportunity_ids
    from public.opportunities as o_active
    where o_active.prospect_id =
        v_prospect_id
      and o_active.lifecycle_state in (
          'NEW',
          'ENGAGED',
          'QUALIFYING',
          'QUALIFIED',
          'BOOKING_READY',
          'BOOKED'
      )
      and (
          v_lead_type =
              'UNKNOWN'
          or o_active.lead_type =
              v_lead_type
          or o_active.lead_type =
              'UNKNOWN'
      )
      and (
          v_location_code =
              'UNKNOWN'
          or o_active.location_code =
              v_location_code
          or o_active.location_code =
              'UNKNOWN'
      );


    v_opportunity_count :=
        coalesce(
            cardinality(
                v_opportunity_ids
            ),
            0
        );


    if v_opportunity_count > 1 then

        return query
        select
            'REVIEW_REQUIRED'::text,
            v_prospect_id,
            null::uuid,
            v_identity_resolution,
            'AMBIGUOUS'::text,
            null::text,
            'OPPORTUNITY_STATE_CONFLICT'::text;

        return;

    end if;


    if v_opportunity_count = 1 then

        v_opportunity_id :=
            v_opportunity_ids[1];


        update public.opportunities as o_update
        set
            lead_type =
                case
                    when
                        lead_type =
                            'UNKNOWN'
                        and
                        v_lead_type <>
                            'UNKNOWN'
                    then v_lead_type
                    else lead_type
                end,

            current_intent =
                case
                    when
                        current_intent =
                            'UNKNOWN'
                        and
                        v_lead_type <>
                            'UNKNOWN'
                    then v_lead_type
                    else current_intent
                end,

            location_code =
                case
                    when
                        location_code =
                            'UNKNOWN'
                        and
                        v_location_code <>
                            'UNKNOWN'
                    then v_location_code
                    else location_code
                end

        where o_update.opportunity_id =
            v_opportunity_id
          and o_update.prospect_id =
            v_prospect_id

        returning o_update.lifecycle_state
        into v_lifecycle_state;


        update public.calls
        set
            prospect_id =
                v_prospect_id,

            opportunity_id =
                v_opportunity_id

        where call_id =
            p_call_id;


        return query
        select
            'RESOLVED'::text,
            v_prospect_id,
            v_opportunity_id,
            v_identity_resolution,
            'EXISTING'::text,
            v_lifecycle_state,
            null::text;

        return;

    end if;


    --------------------------------------------------------------------------
    -- No compatible active opportunity: create one tied idempotently to this
    -- canonical Retell call.
    --------------------------------------------------------------------------

    v_source_channel :=
        case v_call.call_type
            when 'WEB'
                then 'WEB_CALL'
            when 'PHONE'
                then 'PHONE_CALL'
            else 'OTHER'
        end;


    v_source_event_key :=
        'retell-call:' ||
        v_call.provider_call_id;


    insert into public.opportunities as o_created (
        prospect_id,
        lead_type,
        source_channel,
        source_event_key,
        location_code,
        lifecycle_state,
        qualification_state,
        current_intent,
        last_activity_at,
        last_contact_at
    )
    values (
        v_prospect_id,
        v_lead_type,
        v_source_channel,
        v_source_event_key,
        v_location_code,
        'NEW',
        'NOT_STARTED',
        v_lead_type,
        now(),
        now()
    )
    returning
        o_created.opportunity_id,
        o_created.lifecycle_state
    into
        v_opportunity_id,
        v_lifecycle_state;


    update public.calls
    set
        prospect_id =
            v_prospect_id,

        opportunity_id =
            v_opportunity_id

    where call_id =
        p_call_id;


    return query
    select
        'RESOLVED'::text,
        v_prospect_id,
        v_opportunity_id,
        v_identity_resolution,
        'CREATED'::text,
        v_lifecycle_state,
        null::text;

end;
$$;

-- Preserve the existing trusted execution boundary explicitly.
revoke all
on function public.resolve_capture_context_v1(
    uuid,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text
)
from public;

revoke all
on function public.resolve_capture_context_v1(
    uuid,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text
)
from anon;

revoke all
on function public.resolve_capture_context_v1(
    uuid,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text
)
from authenticated;

grant execute
on function public.resolve_capture_context_v1(
    uuid,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    text
)
to service_role;


-- ============================================================================
-- 2. Atomic caller email correction.
-- ============================================================================


create or replace function public.correct_primary_email_v1(
    p_call_id uuid,
    p_email_raw text default null,
    p_email_normalized text default null
)
returns table (
    status text,
    prospect_id uuid,
    opportunity_id uuid,
    corrected_contact_point_id uuid,
    previous_primary_contact_point_id uuid,
    error_code text
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
    v_call public.calls%rowtype;

    v_prospect_status text;
    v_opportunity_lifecycle text;

    v_candidate_ids uuid[];
    v_candidate_count integer := 0;

    v_primary_ids uuid[];
    v_primary_count integer := 0;

    v_existing_ids uuid[];
    v_existing_count integer := 0;

    v_previous_primary_id uuid;
    v_previous_primary_normalized text;
    v_previous_primary_state text;

    v_corrected_contact_point_id uuid;
    v_existing_state text;

    v_email_raw text;
    v_email_normalized text;
begin

    --------------------------------------------------------------------------
    -- Canonical call row is the serialization anchor and server-owned context.
    --------------------------------------------------------------------------

    select *
    into v_call
    from public.calls
    where call_id = p_call_id
    for update;


    if not found then
        return query
        select
            'ERROR'::text,
            null::uuid,
            null::uuid,
            null::uuid,
            null::uuid,
            'CALL_CONTEXT_UNAVAILABLE'::text;

        return;
    end if;


    if v_call.prospect_id is null then
        return query
        select
            'REVIEW_REQUIRED'::text,
            null::uuid,
            v_call.opportunity_id,
            null::uuid,
            null::uuid,
            'PROSPECT_CONTEXT_UNAVAILABLE'::text;

        return;
    end if;


    --------------------------------------------------------------------------
    -- Normalize the caller-supplied correction defensively.
    --------------------------------------------------------------------------

    v_email_raw :=
        nullif(
            btrim(
                p_email_raw
            ),
            ''
        );


    v_email_normalized :=
        nullif(
            lower(
                btrim(
                    p_email_normalized
                )
            ),
            ''
        );


    if v_email_normalized is null then
        return query
        select
            'ERROR'::text,
            v_call.prospect_id,
            v_call.opportunity_id,
            null::uuid,
            null::uuid,
            'INVALID_EMAIL'::text;

        return;
    end if;


    --------------------------------------------------------------------------
    -- Match capture locking order: call row -> corrected email -> prospect.
    --------------------------------------------------------------------------

    perform pg_advisory_xact_lock(
        hashtextextended(
            'IDENTITY:EMAIL:' ||
            v_email_normalized,
            0
        )
    );


    perform pg_advisory_xact_lock(
        hashtextextended(
            'PROSPECT:' ||
            v_call.prospect_id::text,
            0
        )
    );


    --------------------------------------------------------------------------
    -- Prospect must still be canonical and active.
    --------------------------------------------------------------------------

    select p.identity_status
    into v_prospect_status
    from public.prospects as p
    where p.prospect_id =
        v_call.prospect_id
    for update;


    if
        not found
        or v_prospect_status <>
            'ACTIVE'
    then
        return query
        select
            'REVIEW_REQUIRED'::text,
            v_call.prospect_id,
            v_call.opportunity_id,
            null::uuid,
            null::uuid,
            'PROSPECT_STATE_CONFLICT'::text;

        return;
    end if;


    --------------------------------------------------------------------------
    -- Do not mutate contact identity after a booking already exists.
    -- A human must reconcile the attendee contact with the provider booking.
    --------------------------------------------------------------------------

    if v_call.opportunity_id is not null then

        select o.lifecycle_state
        into v_opportunity_lifecycle
        from public.opportunities as o
        where o.opportunity_id =
                v_call.opportunity_id
          and o.prospect_id =
                v_call.prospect_id;


        if not found then
            return query
            select
                'REVIEW_REQUIRED'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                null::uuid,
                null::uuid,
                'OPPORTUNITY_STATE_CONFLICT'::text;

            return;
        end if;


        if
            v_opportunity_lifecycle =
                'BOOKED'
            or exists (
                select 1
                from public.appointments as a
                where a.prospect_id =
                        v_call.prospect_id
                  and a.opportunity_id =
                        v_call.opportunity_id
                  and a.status in (
                        'CREATE_PENDING',
                        'CONFIRMED',
                        'RESCHEDULE_PENDING',
                        'CANCEL_PENDING'
                  )
            )
        then
            return query
            select
                'REVIEW_REQUIRED'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                null::uuid,
                null::uuid,
                'BOOKED_CONTACT_CHANGE_REQUIRES_HUMAN'::text;

            return;
        end if;

    end if;


    --------------------------------------------------------------------------
    -- A corrected email must not silently move identity across prospects.
    --
    -- INVALID contact points are not authoritative identity evidence.
    -- MERGED records resolve to their canonical target.
    --------------------------------------------------------------------------

    select array_agg(
        distinct
        case
            when p.identity_status = 'MERGED'
                then p.merged_into_prospect_id
            else p.prospect_id
        end
    )
    into v_candidate_ids
    from public.contact_points as cp
    join public.prospects as p
      on p.prospect_id = cp.prospect_id
    where cp.contact_type = 'EMAIL'
      and cp.normalized_value =
            v_email_normalized
      and cp.verification_state <>
            'INVALID';


    v_candidate_count :=
        coalesce(
            cardinality(
                v_candidate_ids
            ),
            0
        );


    if v_candidate_count > 1 then
        return query
        select
            'REVIEW_REQUIRED'::text,
            v_call.prospect_id,
            v_call.opportunity_id,
            null::uuid,
            null::uuid,
            'EMAIL_OWNERSHIP_CONFLICT'::text;

        return;
    end if;


    if
        v_candidate_count = 1
        and v_candidate_ids[1] <>
            v_call.prospect_id
    then
        return query
        select
            'REVIEW_REQUIRED'::text,
            v_call.prospect_id,
            v_call.opportunity_id,
            null::uuid,
            null::uuid,
            'EMAIL_OWNERSHIP_CONFLICT'::text;

        return;
    end if;


    --------------------------------------------------------------------------
    -- Detect inconsistent primary-email state instead of guessing.
    --------------------------------------------------------------------------

    select array_agg(
        cp.contact_point_id
        order by cp.created_at,
                 cp.contact_point_id
    )
    into v_primary_ids
    from public.contact_points as cp
    where cp.prospect_id =
            v_call.prospect_id
      and cp.contact_type =
            'EMAIL'
      and cp.is_primary =
            true;


    v_primary_count :=
        coalesce(
            cardinality(
                v_primary_ids
            ),
            0
        );


    if v_primary_count > 1 then
        return query
        select
            'REVIEW_REQUIRED'::text,
            v_call.prospect_id,
            v_call.opportunity_id,
            null::uuid,
            null::uuid,
            'CONTACT_STATE_CONFLICT'::text;

        return;
    end if;


    if v_primary_count = 1 then

        v_previous_primary_id :=
            v_primary_ids[1];


        select
            cp.normalized_value,
            cp.verification_state
        into
            v_previous_primary_normalized,
            v_previous_primary_state
        from public.contact_points as cp
        where cp.contact_point_id =
                v_previous_primary_id
          and cp.prospect_id =
                v_call.prospect_id
        for update;


        if
            v_previous_primary_state =
                'INVALID'
        then
            return query
            select
                'REVIEW_REQUIRED'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                null::uuid,
                v_previous_primary_id,
                'CONTACT_STATE_CONFLICT'::text;

            return;
        end if;


        if
            v_previous_primary_normalized =
                v_email_normalized
        then

            update public.contact_points as cp
            set raw_value =
                coalesce(
                    v_email_raw,
                    cp.raw_value
                )
            where cp.contact_point_id =
                    v_previous_primary_id
              and cp.prospect_id =
                    v_call.prospect_id;


            return query
            select
                'ALREADY_CURRENT'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                v_previous_primary_id,
                v_previous_primary_id,
                null::text;

            return;
        end if;

    end if;


    --------------------------------------------------------------------------
    -- Resolve an existing same-prospect row for the corrected email.
    -- Multiple duplicate rows are a data conflict and require human review.
    --------------------------------------------------------------------------

    select array_agg(
        cp.contact_point_id
        order by cp.created_at,
                 cp.contact_point_id
    )
    into v_existing_ids
    from public.contact_points as cp
    where cp.prospect_id =
            v_call.prospect_id
      and cp.contact_type =
            'EMAIL'
      and cp.normalized_value =
            v_email_normalized;


    v_existing_count :=
        coalesce(
            cardinality(
                v_existing_ids
            ),
            0
        );


    if v_existing_count > 1 then
        return query
        select
            'REVIEW_REQUIRED'::text,
            v_call.prospect_id,
            v_call.opportunity_id,
            null::uuid,
            v_previous_primary_id,
            'CONTACT_STATE_CONFLICT'::text;

        return;
    end if;


    if v_existing_count = 1 then

        v_corrected_contact_point_id :=
            v_existing_ids[1];


        select cp.verification_state
        into v_existing_state
        from public.contact_points as cp
        where cp.contact_point_id =
                v_corrected_contact_point_id
          and cp.prospect_id =
                v_call.prospect_id
        for update;


        if v_existing_state in (
            'INVALID',
            'REVIEW_REQUIRED'
        ) then
            return query
            select
                'REVIEW_REQUIRED'::text,
                v_call.prospect_id,
                v_call.opportunity_id,
                v_corrected_contact_point_id,
                v_previous_primary_id,
                'CONTACT_STATE_CONFLICT'::text;

            return;
        end if;

    end if;


    --------------------------------------------------------------------------
    -- Demote and invalidate the caller-corrected primary email.
    --
    -- Eligibility tied directly to that invalid contact point becomes
    -- ineligible so a later asynchronous workflow cannot use stale contact.
    --------------------------------------------------------------------------

    if
        v_previous_primary_id is not null
        and (
            v_corrected_contact_point_id is null
            or v_previous_primary_id <>
                v_corrected_contact_point_id
        )
    then

        update public.contact_points as cp
        set
            is_primary =
                false,

            verification_state =
                'INVALID'

        where cp.contact_point_id =
                v_previous_primary_id
          and cp.prospect_id =
                v_call.prospect_id;


        update public.contact_eligibility as ce
        set
            eligibility_state =
                'INELIGIBLE',

            reason_code =
                'CONTACT_CORRECTED',

            effective_at =
                now(),

            expires_at =
                null

        where ce.prospect_id =
                v_call.prospect_id
          and ce.contact_point_id =
                v_previous_primary_id;

    end if;


    --------------------------------------------------------------------------
    -- Promote or create the corrected primary email.
    --------------------------------------------------------------------------

    if v_corrected_contact_point_id is not null then

        update public.contact_points as cp
        set
            raw_value =
                coalesce(
                    v_email_raw,
                    cp.raw_value
                ),

            is_primary =
                true,

            verification_state =
                cp.verification_state

        where cp.contact_point_id =
                v_corrected_contact_point_id
          and cp.prospect_id =
                v_call.prospect_id;

    else

        insert into public.contact_points (
            prospect_id,
            contact_type,
            raw_value,
            normalized_value,
            is_primary,
            verification_state
        )
        values (
            v_call.prospect_id,
            'EMAIL',
            coalesce(
                v_email_raw,
                v_email_normalized
            ),
            v_email_normalized,
            true,
            'UNVERIFIED'
        )
        returning contact_point_id
        into v_corrected_contact_point_id;

    end if;


    --------------------------------------------------------------------------
    -- Append a non-PII audit event for the correction.
    --------------------------------------------------------------------------

    insert into public.audit_events (
        correlation_id,
        actor_type,
        actor_id,
        entity_type,
        entity_id,
        action,
        reason_code,
        before_state,
        after_state,
        metadata
    )
    values (
        v_call.correlation_id,
        'SYSTEM',
        'retell:correct_email_v1',
        'PROSPECT',
        v_call.prospect_id,
        'PRIMARY_EMAIL_CORRECTED',
        'CALLER_CORRECTION',

        jsonb_build_object(
            'previous_primary_contact_point_id',
                v_previous_primary_id
        ),

        jsonb_build_object(
            'corrected_contact_point_id',
                v_corrected_contact_point_id
        ),

        jsonb_build_object(
            'call_id',
                v_call.call_id,

            'opportunity_id',
                v_call.opportunity_id,

            'source',
                'CALLER_CORRECTION'
        )
    );


    return query
    select
        'CORRECTED'::text,
        v_call.prospect_id,
        v_call.opportunity_id,
        v_corrected_contact_point_id,
        v_previous_primary_id,
        null::text;

end;
$$;


revoke all
on function public.correct_primary_email_v1(
    uuid,
    text,
    text
)
from public;

revoke all
on function public.correct_primary_email_v1(
    uuid,
    text,
    text
)
from anon;

revoke all
on function public.correct_primary_email_v1(
    uuid,
    text,
    text
)
from authenticated;

grant execute
on function public.correct_primary_email_v1(
    uuid,
    text,
    text
)
to service_role;


-- ============================================================================
-- END
-- ============================================================================
