alter table public.opportunities
add column initial_enquiry_summary text null;


alter table public.opportunities
add constraint opportunities_initial_enquiry_summary_length_check
check (
    initial_enquiry_summary is null
    or (
        char_length(btrim(initial_enquiry_summary)) between 1 and 1000
    )
);


comment on column public.opportunities.initial_enquiry_summary is
'Initial non-sensitive business enquiry context captured when the opportunity is first resolved. This field is enrich-only and must not be overwritten by later calls.';


create or replace function public.resolve_capture_context_v2(
    p_call_id uuid,

    p_first_name text default null,
    p_last_name text default null,
    p_company_name text default null,

    p_email_raw text default null,
    p_email_normalized text default null,

    p_phone_raw text default null,
    p_phone_normalized text default null,

    p_location_code text default null,
    p_stated_intent text default null,

    p_initial_enquiry_summary text default null
)
returns table(
    status text,
    prospect_id uuid,
    opportunity_id uuid,
    identity_resolution text,
    opportunity_resolution text,
    current_lifecycle_state text,
    error_code text
)
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_status text;

    v_prospect_id uuid;
    v_opportunity_id uuid;

    v_identity_resolution text;
    v_opportunity_resolution text;

    v_current_lifecycle_state text;
    v_error_code text;

    v_initial_enquiry_summary text;
begin

    --------------------------------------------------------------------------
    -- Normalize optional enquiry context defensively.
    --
    -- Application validation remains authoritative for the 1000-character
    -- contract. Database normalization protects direct/internal callers from
    -- storing meaningless whitespace.
    --------------------------------------------------------------------------

    v_initial_enquiry_summary :=
        nullif(
            regexp_replace(
                btrim(
                    p_initial_enquiry_summary
                ),
                '[[:space:]]+',
                ' ',
                'g'
            ),
            ''
        );


    --------------------------------------------------------------------------
    -- Preserve the proven V1 identity/opportunity resolver as the canonical
    -- implementation for matching, locking, creation, and lifecycle rules.
    --------------------------------------------------------------------------

    select
        resolved.status,
        resolved.prospect_id,
        resolved.opportunity_id,
        resolved.identity_resolution,
        resolved.opportunity_resolution,
        resolved.current_lifecycle_state,
        resolved.error_code

    into
        v_status,
        v_prospect_id,
        v_opportunity_id,
        v_identity_resolution,
        v_opportunity_resolution,
        v_current_lifecycle_state,
        v_error_code

    from public.resolve_capture_context_v1(
        p_call_id =>
            p_call_id,

        p_first_name =>
            p_first_name,

        p_last_name =>
            p_last_name,

        p_company_name =>
            p_company_name,

        p_email_raw =>
            p_email_raw,

        p_email_normalized =>
            p_email_normalized,

        p_phone_raw =>
            p_phone_raw,

        p_phone_normalized =>
            p_phone_normalized,

        p_location_code =>
            p_location_code,

        p_stated_intent =>
            p_stated_intent
    ) as resolved;


    --------------------------------------------------------------------------
    -- Enrich the opportunity with its initial caller-provided business need.
    --
    -- First non-empty value wins. A later call or AI rephrasing must never
    -- overwrite the original opportunity context.
    --------------------------------------------------------------------------

    if
        v_status = 'RESOLVED'
        and v_opportunity_id is not null
        and v_initial_enquiry_summary is not null
    then

        update public.opportunities as o
        set initial_enquiry_summary =
            v_initial_enquiry_summary

        where o.opportunity_id =
                v_opportunity_id

          and o.prospect_id =
                v_prospect_id

          and o.initial_enquiry_summary
                is null;

    end if;


    --------------------------------------------------------------------------
    -- Preserve the exact V1 response contract.
    --------------------------------------------------------------------------

    return query
    select
        v_status,
        v_prospect_id,
        v_opportunity_id,
        v_identity_resolution,
        v_opportunity_resolution,
        v_current_lifecycle_state,
        v_error_code;

end;
$function$;

--------------------------------------------------------------------------
-- Restrict direct RPC execution.
--
-- Retell never calls this database function directly. Only the trusted
-- Supabase Edge Function using the service role may execute it.
--------------------------------------------------------------------------

revoke execute on function public.resolve_capture_context_v2(
    uuid,
    text,
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

revoke execute on function public.resolve_capture_context_v2(
    uuid,
    text,
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

revoke execute on function public.resolve_capture_context_v2(
    uuid,
    text,
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

grant execute on function public.resolve_capture_context_v2(
    uuid,
    text,
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