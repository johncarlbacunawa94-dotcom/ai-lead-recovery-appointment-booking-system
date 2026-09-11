-- Phase 4
-- Resolve and validate authoritative persisted evidence for
-- RETELL_CALL_ANALYZED post-call processing.
--
-- IMPORTANT:
-- - Does NOT perform lifecycle reconciliation.
-- - Does NOT call AI.
-- - Does NOT mutate calls/opportunities.
-- - Internal IDs are resolved from trusted persisted state.

create or replace function public.prepare_retell_post_call_analysis_v1(
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

    disconnection_reason text,

    transcript_reference text,
    knowledge_retrieval_reference text,

    existing_summary text,
    existing_detected_intent text,
    existing_qualification_result text,
    existing_appointment_result text,
    existing_post_call_analysis jsonb,

    evidence_ready boolean,
    missing_evidence text[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_worker_id text;

    v_outbox public.outbox_events%rowtype;
    v_raw public.raw_provider_events%rowtype;
    v_call public.calls%rowtype;

    v_call_payload jsonb;

    v_provider_call_id text;
    v_provider_call_type text;
    v_provider_call_status text;

    v_start_ms bigint;
    v_end_ms bigint;

    v_provider_started_at timestamptz;
    v_provider_ended_at timestamptz;
    v_provider_duration_ms bigint;

    v_disposition text;
    v_next_action text;

    v_evidence_ready boolean;
    v_missing_evidence text[];
begin
    --------------------------------------------------------------------------
    -- 1. Validate invocation.
    --------------------------------------------------------------------------

    if p_outbox_event_id is null then
        raise exception
            'outbox event ID is required'
            using errcode = '22023';
    end if;


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
    -- 2. Resolve and verify the currently claimed outbox work item.
    --------------------------------------------------------------------------

    select oe.*
    into v_outbox
    from public.outbox_events as oe
    where oe.outbox_event_id = p_outbox_event_id;


    if not found then
        raise exception
            'outbox event does not exist'
            using errcode = '22023';
    end if;


    if v_outbox.event_type <> 'RETELL_CALL_ANALYZED' then
        raise exception
            'outbox event is not RETELL_CALL_ANALYZED'
            using errcode = '22023';
    end if;


    if v_outbox.status <> 'PROCESSING' then
        raise exception
            'outbox event is not currently processing'
            using errcode = '22000';
    end if;


    if v_outbox.locked_at is null then
        raise exception
            'outbox event has no active worker lease'
            using errcode = '22000';
    end if;


    if v_outbox.locked_by is distinct from v_worker_id then
        raise exception
            'outbox event is leased to another worker'
            using errcode = '22000';
    end if;


    if v_outbox.source_raw_provider_event_id is null then
        raise exception
            'outbox event has no source raw provider event'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 3. Lifecycle reconciliation must already have bound the canonical call.
    --------------------------------------------------------------------------

    if v_outbox.aggregate_type <> 'CALL' then
        raise exception
            'outbox aggregate type is not CALL'
            using errcode = '22000';
    end if;


    if v_outbox.aggregate_id is null then
        raise exception
            'canonical call has not been bound; lifecycle reconciliation must run first'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 4. Resolve immutable authenticated provider evidence.
    --------------------------------------------------------------------------

    select rpe.*
    into v_raw
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id =
        v_outbox.source_raw_provider_event_id;


    if not found then
        raise exception
            'linked raw provider event does not exist'
            using errcode = '22023';
    end if;


    if v_raw.provider <> 'RETELL' then
        raise exception
            'linked raw provider event is not from Retell'
            using errcode = '22023';
    end if;


    if v_raw.signature_valid is distinct from true then
        raise exception
            'linked raw provider event is not signature verified'
            using errcode = '22023';
    end if;


    if lower(btrim(coalesce(v_raw.event_type, ''))) <> 'call_analyzed' then
        raise exception
            'linked raw provider event is not call_analyzed'
            using errcode = '22023';
    end if;


    if coalesce(v_raw.payload ->> 'event', '') <> 'call_analyzed' then
        raise exception
            'provider payload event does not match call_analyzed'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 5. Resolve the persisted Retell call envelope.
    --------------------------------------------------------------------------

    v_call_payload :=
        v_raw.payload -> 'call';


    if (
        v_call_payload is null
        or jsonb_typeof(v_call_payload) <> 'object'
    ) then
        raise exception
            'Retell call_analyzed event has no valid call object'
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
            'Retell call_analyzed event has no call_id'
            using errcode = '22023';
    end if;


    v_provider_call_type :=
        nullif(
            btrim(
                coalesce(
                    v_call_payload ->> 'call_type',
                    ''
                )
            ),
            ''
        );


    v_provider_call_status :=
        nullif(
            btrim(
                coalesce(
                    v_call_payload ->> 'call_status',
                    ''
                )
            ),
            ''
        );


    --------------------------------------------------------------------------
    -- 6. Resolve the canonical call only through trusted persisted binding.
    --------------------------------------------------------------------------

    select c.*
    into v_call
    from public.calls as c
    where c.call_id = v_outbox.aggregate_id;


    if not found then
        raise exception
            'bound canonical call does not exist'
            using errcode = '22000';
    end if;


    if v_call.provider <> 'RETELL' then
        raise exception
            'bound canonical call is not a Retell call'
            using errcode = '22000';
    end if;


    if v_call.provider_call_id is distinct from v_provider_call_id then
        raise exception
            'canonical call does not match provider call ID'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 7. Lifecycle ownership remains reconcile_retell_call_lifecycle_v1.
    --
    -- This function only verifies the state produced by that RPC.
    --------------------------------------------------------------------------

    if v_call.status not in (
        'ANALYSIS_PENDING',
        'ANALYZED',
        'POST_PROCESSED'
    ) then
        raise exception
            'canonical call is not in a permitted post-call analysis state'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 8. Parse provider timestamps from the already-validated persisted event.
    --------------------------------------------------------------------------

    if (
        v_call_payload ? 'start_timestamp'
        and jsonb_typeof(
            v_call_payload -> 'start_timestamp'
        ) = 'number'
    ) then
        v_start_ms :=
            (v_call_payload ->> 'start_timestamp')::bigint;

        v_provider_started_at :=
            to_timestamp(
                v_start_ms::double precision /
                1000.0
            );
    end if;


    if (
        v_call_payload ? 'end_timestamp'
        and jsonb_typeof(
            v_call_payload -> 'end_timestamp'
        ) = 'number'
    ) then
        v_end_ms :=
            (v_call_payload ->> 'end_timestamp')::bigint;

        v_provider_ended_at :=
            to_timestamp(
                v_end_ms::double precision /
                1000.0
            );
    end if;


    if (
        v_start_ms is not null
        and v_end_ms is not null
        and v_end_ms >= v_start_ms
    ) then
        v_provider_duration_ms :=
            v_end_ms - v_start_ms;
    elsif v_call.duration_ms is not null then
        v_provider_duration_ms :=
            v_call.duration_ms::bigint;
    end if;


    --------------------------------------------------------------------------
    -- 9. Determine idempotent processing disposition.
    --------------------------------------------------------------------------

    if v_call.status = 'POST_PROCESSED' then

        v_disposition :=
            'ALREADY_POST_PROCESSED';

        v_next_action :=
            'COMPLETE_OUTBOX';

        v_evidence_ready :=
            null;

        v_missing_evidence :=
            null;


    elsif v_call.status = 'ANALYZED' then

        v_disposition :=
            'ALREADY_ANALYZED';

        v_next_action :=
            'COMPLETE_OUTBOX';

        v_evidence_ready :=
            null;

        v_missing_evidence :=
            null;


    else

        v_disposition :=
            'PREPARED';

        ----------------------------------------------------------------------
        -- Current persisted call_analyzed evidence contains no transcript.
        --
        -- transcript_reference is only a locator/reference. It is not treated
        -- as transcript content suitable for PostCallAnalysisV1.
        ----------------------------------------------------------------------

        v_evidence_ready :=
            false;

        v_missing_evidence :=
            array[
                'TRANSCRIPT_CONTENT'
            ]::text[];


        if nullif(
            btrim(
                coalesce(
                    v_call.transcript_reference,
                    ''
                )
            ),
            ''
        ) is not null then

            v_next_action :=
                'RESOLVE_TRANSCRIPT_REFERENCE';

        else

            v_next_action :=
                'ENRICH_TRANSCRIPT';

        end if;

    end if;


    --------------------------------------------------------------------------
    -- 10. Return authoritative preparation context.
    --
    -- Internal IDs are returned for controlled backend/workflow correlation.
    -- They must not become model-controlled inputs.
    --------------------------------------------------------------------------

    return query
    select
        v_disposition,
        v_next_action,

        v_outbox.outbox_event_id,
        v_raw.raw_provider_event_id,

        v_call.call_id,
        v_call.correlation_id,
        v_call.prospect_id,
        v_call.opportunity_id,

        v_provider_call_id,
        v_call.status,

        v_provider_call_type,
        v_provider_call_status,

        v_provider_started_at,
        v_provider_ended_at,
        v_provider_duration_ms,

        v_call.disconnection_reason,

        v_call.transcript_reference,
        v_call.knowledge_retrieval_reference,

        v_call.summary,
        v_call.detected_intent,
        v_call.qualification_result,
        v_call.appointment_result,
        v_call.post_call_analysis,

        v_evidence_ready,
        v_missing_evidence;
end;
$function$;


comment on function public.prepare_retell_post_call_analysis_v1(uuid, text)
is
'Phase 4 post-call preparation boundary. Validates a claimed RETELL_CALL_ANALYZED outbox lease, resolves authenticated provider evidence and the already-reconciled canonical call, and returns persisted post-call context. Performs no lifecycle mutation, AI inference, or opportunity mutation.';


revoke all
on function public.prepare_retell_post_call_analysis_v1(uuid, text)
from public;


revoke all
on function public.prepare_retell_post_call_analysis_v1(uuid, text)
from anon;


revoke all
on function public.prepare_retell_post_call_analysis_v1(uuid, text)
from authenticated;


grant execute
on function public.prepare_retell_post_call_analysis_v1(uuid, text)
to service_role;