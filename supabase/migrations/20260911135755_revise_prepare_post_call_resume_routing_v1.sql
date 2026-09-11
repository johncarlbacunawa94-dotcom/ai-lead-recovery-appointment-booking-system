-- Phase 4
-- Correct post-call resume routing.
--
-- Problem:
-- The proven preparation function currently routes an already-ANALYZED call
-- directly to COMPLETE_OUTBOX.
--
-- That is unsafe if:
--   persist_post_call_analysis_v1 succeeds,
--   then the worker crashes before
--   apply_post_call_business_state_v1 executes.
--
-- Correct resume routing:
--
-- ANALYSIS_PENDING
--   -> RUN_POST_CALL_ANALYSIS
--
-- ANALYZED
--   -> APPLY_POST_CALL_BUSINESS_STATE
--
-- POST_PROCESSED
--   -> COMPLETE_OUTBOX
--
-- This migration preserves the proven preparation implementation unchanged
-- as a private core and exposes a thin corrected routing wrapper.


-------------------------------------------------------------------------------
-- 1. Preserve the proven implementation unchanged.
-------------------------------------------------------------------------------

alter function public.prepare_retell_post_call_analysis_v1(
    uuid,
    text
)
rename to prepare_retell_post_call_analysis_core_v1;


-------------------------------------------------------------------------------
-- 2. The core is implementation-only.
--
-- External workers should call prepare_retell_post_call_analysis_v1,
-- not the core directly.
-------------------------------------------------------------------------------

revoke all
on function public.prepare_retell_post_call_analysis_core_v1(
    uuid,
    text
)
from public, anon, authenticated, service_role;


comment on function public.prepare_retell_post_call_analysis_core_v1(
    uuid,
    text
)
is
'Internal proven Phase 4 post-call evidence-preparation implementation. Use prepare_retell_post_call_analysis_v1 as the public worker boundary.';


-------------------------------------------------------------------------------
-- 3. Recreate the public preparation boundary.
--
-- All evidence-resolution and validation behavior comes from the proven core.
-- Only retry/resume routing is normalized here.
-------------------------------------------------------------------------------

create function public.prepare_retell_post_call_analysis_v1(
    p_outbox_event_id uuid,
    p_worker_id text
)
returns table (
    disposition text,
    next_action text,

    outbox_event_id uuid,
    raw_provider_event_id uuid,

    canonical_call_id uuid,
    correlation_id uuid,
    prospect_id uuid,
    opportunity_id uuid,

    provider_call_id text,
    canonical_call_status text,

    provider_call_type text,
    provider_call_status text,

    provider_started_at timestamptz,
    provider_ended_at timestamptz,
    provider_duration_ms bigint,

    provider_disconnection_reason text,

    provider_transcript text,
    provider_transcript_object jsonb,

    provider_call_analysis jsonb,
    provider_call_summary text,
    provider_in_voicemail boolean,
    provider_user_sentiment text,
    provider_call_successful boolean,
    provider_custom_analysis_data jsonb,

    provider_metadata jsonb,
    provider_knowledge_retrieval_reference text,

    canonical_transcript_reference text,
    canonical_knowledge_retrieval_reference text,

    existing_summary text,
    existing_detected_intent text,
    existing_qualification_result text,
    existing_appointment_result text,
    existing_post_call_analysis jsonb,

    evidence_ready boolean,
    missing_evidence text[]
)
language sql
security definer
set search_path = public, pg_temp
as $function$

    select
        p.disposition,

        case
            ------------------------------------------------------------------
            -- Critical resume correction.
            --
            -- Analysis already persisted, but deterministic business-state
            -- application may still be outstanding.
            ------------------------------------------------------------------
            when p.disposition = 'ALREADY_ANALYZED'
             and p.canonical_call_status = 'ANALYZED'
                then 'APPLY_POST_CALL_BUSINESS_STATE'

            ------------------------------------------------------------------
            -- All other proven routing remains unchanged.
            --
            -- In particular:
            -- ANALYSIS_PENDING -> RUN_POST_CALL_ANALYSIS
            -- POST_PROCESSED   -> COMPLETE_OUTBOX
            ------------------------------------------------------------------
            else p.next_action
        end as next_action,

        p.outbox_event_id,
        p.raw_provider_event_id,

        p.canonical_call_id,
        p.correlation_id,
        p.prospect_id,
        p.opportunity_id,

        p.provider_call_id,
        p.canonical_call_status,

        p.provider_call_type,
        p.provider_call_status,

        p.provider_started_at,
        p.provider_ended_at,
        p.provider_duration_ms,

        p.provider_disconnection_reason,

        p.provider_transcript,
        p.provider_transcript_object,

        p.provider_call_analysis,
        p.provider_call_summary,
        p.provider_in_voicemail,
        p.provider_user_sentiment,
        p.provider_call_successful,
        p.provider_custom_analysis_data,

        p.provider_metadata,
        p.provider_knowledge_retrieval_reference,

        p.canonical_transcript_reference,
        p.canonical_knowledge_retrieval_reference,

        p.existing_summary,
        p.existing_detected_intent,
        p.existing_qualification_result,
        p.existing_appointment_result,
        p.existing_post_call_analysis,

        p.evidence_ready,
        p.missing_evidence

    from public.prepare_retell_post_call_analysis_core_v1(
        p_outbox_event_id,
        p_worker_id
    ) as p;

$function$;


-------------------------------------------------------------------------------
-- 4. Document the corrected public contract.
-------------------------------------------------------------------------------

comment on function public.prepare_retell_post_call_analysis_v1(
    uuid,
    text
)
is
'Phase 4 public post-call preparation boundary. Preserves the proven evidence-resolution implementation and provides crash-safe resume routing: ANALYSIS_PENDING -> RUN_POST_CALL_ANALYSIS, ANALYZED -> APPLY_POST_CALL_BUSINESS_STATE, POST_PROCESSED -> COMPLETE_OUTBOX. Performs no lifecycle, AI, opportunity, booking, eligibility, or outbox mutation.';


-------------------------------------------------------------------------------
-- 5. Preserve worker-facing security boundary.
-------------------------------------------------------------------------------

revoke all
on function public.prepare_retell_post_call_analysis_v1(
    uuid,
    text
)
from public;


revoke all
on function public.prepare_retell_post_call_analysis_v1(
    uuid,
    text
)
from anon;


revoke all
on function public.prepare_retell_post_call_analysis_v1(
    uuid,
    text
)
from authenticated;


grant execute
on function public.prepare_retell_post_call_analysis_v1(
    uuid,
    text
)
to service_role;