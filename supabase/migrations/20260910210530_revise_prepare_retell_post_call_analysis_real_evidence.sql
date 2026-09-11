-- Phase 4
-- Revise prepare_retell_post_call_analysis_v1 after validating a genuine
-- signed Retell call_analyzed payload.
--
-- This function:
-- - validates claimed post-call work;
-- - resolves authoritative persisted provider evidence;
-- - verifies lifecycle reconciliation already occurred;
-- - exposes transcript/provider analysis for later PostCallAnalysisV1;
-- - performs NO lifecycle mutation;
-- - performs NO AI inference;
-- - performs NO opportunity mutation.

drop function if exists
    public.prepare_retell_post_call_analysis_v1(uuid, text);


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

    v_provider_transcript text;
    v_provider_transcript_object jsonb;
    v_provider_call_analysis jsonb;

    v_provider_call_summary text;
    v_provider_in_voicemail boolean;
    v_provider_user_sentiment text;
    v_provider_call_successful boolean;
    v_provider_custom_analysis_data jsonb;

    v_provider_metadata jsonb;
    v_provider_knowledge_reference text;
    v_provider_disconnection_reason text;

    v_start_ms bigint;
    v_end_ms bigint;
    v_duration_ms bigint;

    v_provider_started_at timestamptz;
    v_provider_ended_at timestamptz;

    v_disposition text;
    v_next_action text;

    v_evidence_ready boolean;
    v_missing_evidence text[];
    v_expected_event_key text;
begin
    --------------------------------------------------------------------------
    -- 1. Invocation validation.
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
    -- 2. Resolve currently claimed analyzed-event work.
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


    if v_outbox.aggregate_type <> 'CALL' then
        raise exception
            'outbox aggregate type is not CALL'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 3. Lifecycle reconciliation must already have bound the call.
    --------------------------------------------------------------------------

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
    -- 5. Validate Retell call envelope.
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


    v_expected_event_key :=
        'RETELL:' ||
        v_provider_call_id ||
        ':call_analyzed';


    if v_raw.event_key <> v_expected_event_key then
        raise exception
            'raw provider event key does not match call_analyzed payload'
            using errcode = '22000';
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


    v_provider_disconnection_reason :=
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
    -- 6. Resolve canonical call through trusted persisted binding.
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
    -- 8. Parse authoritative provider timestamps.
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
            (v_call_payload ->> 'start_timestamp')::bigint;

        if v_start_ms < 0 then
            raise exception
                'Retell start_timestamp cannot be negative'
                using errcode = '22023';
        end if;

        v_provider_started_at :=
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
            (v_call_payload ->> 'end_timestamp')::bigint;

        if v_end_ms < 0 then
            raise exception
                'Retell end_timestamp cannot be negative'
                using errcode = '22023';
        end if;

        v_provider_ended_at :=
            to_timestamp(
                v_end_ms::double precision /
                1000.0
            );
    end if;


    if (
        v_provider_started_at is not null
        and v_provider_ended_at is not null
        and v_provider_ended_at < v_provider_started_at
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

        v_duration_ms :=
            (v_call_payload ->> 'duration_ms')::bigint;

        if v_duration_ms < 0 then
            raise exception
                'Retell duration_ms cannot be negative'
                using errcode = '22023';
        end if;

    elsif (
        v_start_ms is not null
        and v_end_ms is not null
    ) then
        v_duration_ms :=
            v_end_ms - v_start_ms;

    elsif v_call.duration_ms is not null then
        v_duration_ms :=
            v_call.duration_ms::bigint;
    end if;


    --------------------------------------------------------------------------
    -- 9. Extract transcript evidence.
    --------------------------------------------------------------------------

    if (
        v_call_payload ? 'transcript'
        and v_call_payload -> 'transcript'
            <> 'null'::jsonb
    ) then
        if jsonb_typeof(
            v_call_payload -> 'transcript'
        ) <> 'string' then
            raise exception
                'Retell transcript must be a string'
                using errcode = '22023';
        end if;

        v_provider_transcript :=
            nullif(
                btrim(
                    v_call_payload ->> 'transcript'
                ),
                ''
            );
    end if;


    if (
        v_call_payload ? 'transcript_object'
        and v_call_payload -> 'transcript_object'
            <> 'null'::jsonb
    ) then
        if jsonb_typeof(
            v_call_payload -> 'transcript_object'
        ) <> 'array' then
            raise exception
                'Retell transcript_object must be an array'
                using errcode = '22023';
        end if;

        v_provider_transcript_object :=
            v_call_payload -> 'transcript_object';
    end if;


    --------------------------------------------------------------------------
    -- 10. Extract Retell provider analysis as non-authoritative evidence.
    --------------------------------------------------------------------------

    if (
        v_call_payload ? 'call_analysis'
        and v_call_payload -> 'call_analysis'
            <> 'null'::jsonb
    ) then
        if jsonb_typeof(
            v_call_payload -> 'call_analysis'
        ) <> 'object' then
            raise exception
                'Retell call_analysis must be an object'
                using errcode = '22023';
        end if;

        v_provider_call_analysis :=
            v_call_payload -> 'call_analysis';


        v_provider_call_summary :=
            nullif(
                btrim(
                    coalesce(
                        v_provider_call_analysis
                            ->> 'call_summary',
                        ''
                    )
                ),
                ''
            );


        if (
            v_provider_call_analysis ? 'in_voicemail'
            and v_provider_call_analysis -> 'in_voicemail'
                <> 'null'::jsonb
        ) then
            if jsonb_typeof(
                v_provider_call_analysis -> 'in_voicemail'
            ) <> 'boolean' then
                raise exception
                    'Retell call_analysis.in_voicemail must be boolean'
                    using errcode = '22023';
            end if;

            v_provider_in_voicemail :=
                (
                    v_provider_call_analysis
                        ->> 'in_voicemail'
                )::boolean;
        end if;


        v_provider_user_sentiment :=
            nullif(
                btrim(
                    coalesce(
                        v_provider_call_analysis
                            ->> 'user_sentiment',
                        ''
                    )
                ),
                ''
            );


        if (
            v_provider_call_analysis ? 'call_successful'
            and v_provider_call_analysis -> 'call_successful'
                <> 'null'::jsonb
        ) then
            if jsonb_typeof(
                v_provider_call_analysis -> 'call_successful'
            ) <> 'boolean' then
                raise exception
                    'Retell call_analysis.call_successful must be boolean'
                    using errcode = '22023';
            end if;

            v_provider_call_successful :=
                (
                    v_provider_call_analysis
                        ->> 'call_successful'
                )::boolean;
        end if;


        v_provider_custom_analysis_data :=
            v_provider_call_analysis
                -> 'custom_analysis_data';
    end if;


    --------------------------------------------------------------------------
    -- 11. Optional provider metadata / knowledge evidence.
    --------------------------------------------------------------------------

    v_provider_metadata :=
        v_call_payload -> 'metadata';


    v_provider_knowledge_reference :=
        nullif(
            btrim(
                coalesce(
                    v_call_payload
                        ->> 'knowledge_base_retrieved_contents_url',
                    ''
                )
            ),
            ''
        );


    --------------------------------------------------------------------------
    -- 12. Determine idempotent processing disposition.
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

        v_missing_evidence :=
            array[]::text[];


        if v_provider_transcript is null then
            v_missing_evidence :=
                array_append(
                    v_missing_evidence,
                    'TRANSCRIPT_CONTENT'
                );
        end if;


        v_evidence_ready :=
            cardinality(v_missing_evidence) = 0;


        if v_evidence_ready then
            v_next_action :=
                'RUN_POST_CALL_ANALYSIS';
        elsif nullif(
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
    -- 13. Return authoritative preparation context.
    --
    -- Provider call_analysis is provider-derived evidence only.
    -- It must not directly mutate authoritative business state.
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
        v_duration_ms,

        v_provider_disconnection_reason,

        v_provider_transcript,
        v_provider_transcript_object,

        v_provider_call_analysis,
        v_provider_call_summary,
        v_provider_in_voicemail,
        v_provider_user_sentiment,
        v_provider_call_successful,
        v_provider_custom_analysis_data,

        v_provider_metadata,
        v_provider_knowledge_reference,

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


comment on function
    public.prepare_retell_post_call_analysis_v1(uuid, text)
is
'Phase 4 post-call preparation boundary. Validates a claimed RETELL_CALL_ANALYZED lease, resolves authenticated persisted Retell transcript/provider analysis evidence and the already-reconciled canonical call, and returns controlled post-call context. Performs no lifecycle mutation, AI inference, or opportunity mutation.';


revoke all
on function
    public.prepare_retell_post_call_analysis_v1(uuid, text)
from public;


revoke all
on function
    public.prepare_retell_post_call_analysis_v1(uuid, text)
from anon;


revoke all
on function
    public.prepare_retell_post_call_analysis_v1(uuid, text)
from authenticated;


grant execute
on function
    public.prepare_retell_post_call_analysis_v1(uuid, text)
to service_role;