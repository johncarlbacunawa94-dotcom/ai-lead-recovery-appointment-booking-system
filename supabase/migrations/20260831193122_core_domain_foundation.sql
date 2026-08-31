-- ============================================================================
-- AI Lead Recovery & Appointment Booking System
-- Migration 001: Core Domain Foundation
--
-- Authoritative project:
-- Meridian Professional Training & Services — Demo
--
-- Rules:
-- - PostgreSQL is the authoritative business-state store.
-- - Prospect identity is separate from commercial opportunity.
-- - Critical lifecycle/contact/booking state is deterministic.
-- - Provider events and audits preserve traceability.
-- - No public client access is granted at this stage.
-- ============================================================================

set lock_timeout = '10s';

create extension if not exists pgcrypto with schema extensions;

-- ============================================================================
-- SHARED UPDATED_AT TRIGGER
-- ============================================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

revoke all on function public.set_updated_at() from public, anon, authenticated;


-- ============================================================================
-- 1. PROSPECTS
-- Stable person/business-contact identity.
-- ============================================================================

create table public.prospects (
    prospect_id uuid primary key default gen_random_uuid(),

    first_name text,
    last_name text,
    company_name text,

    primary_location_code text not null default 'UNKNOWN'
        check (
            primary_location_code in (
                'BRISBANE',
                'MELBOURNE',
                'SYDNEY',
                'PERTH',
                'OTHER',
                'UNKNOWN'
            )
        ),

    identity_status text not null default 'ACTIVE'
        check (
            identity_status in (
                'ACTIVE',
                'REVIEW_REQUIRED',
                'MERGED'
            )
        ),

    merged_into_prospect_id uuid
        references public.prospects(prospect_id),

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint prospects_no_self_merge
        check (
            merged_into_prospect_id is null
            or merged_into_prospect_id <> prospect_id
        ),

    constraint prospects_merge_state_consistency
        check (
            (
                identity_status = 'MERGED'
                and merged_into_prospect_id is not null
            )
            or
            (
                identity_status <> 'MERGED'
                and merged_into_prospect_id is null
            )
        )
);

create index prospects_identity_status_idx
    on public.prospects(identity_status);

create index prospects_location_idx
    on public.prospects(primary_location_code);

create trigger prospects_set_updated_at
before update on public.prospects
for each row execute function public.set_updated_at();


-- ============================================================================
-- 2. CONTACT POINTS
-- Email/phone identities attached to prospects.
--
-- IMPORTANT:
-- normalized_value is intentionally NOT globally unique.
-- Multiple records may legitimately share a phone/email and ambiguous matches
-- must remain representable for human review.
-- ============================================================================

create table public.contact_points (
    contact_point_id uuid primary key default gen_random_uuid(),

    prospect_id uuid not null
        references public.prospects(prospect_id),

    contact_type text not null
        check (
            contact_type in (
                'EMAIL',
                'PHONE'
            )
        ),

    label text,

    raw_value text not null,
    normalized_value text not null,

    is_primary boolean not null default false,

    verification_state text not null default 'UNVERIFIED'
        check (
            verification_state in (
                'UNVERIFIED',
                'VERIFIED',
                'INVALID',
                'REVIEW_REQUIRED'
            )
        ),

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint contact_points_normalized_not_blank
        check (length(btrim(normalized_value)) > 0),

    constraint contact_points_id_prospect_unique
        unique (contact_point_id, prospect_id)
);

create index contact_points_prospect_idx
    on public.contact_points(prospect_id);

create index contact_points_normalized_lookup_idx
    on public.contact_points(contact_type, normalized_value);

create index contact_points_primary_idx
    on public.contact_points(prospect_id, contact_type, is_primary);

create trigger contact_points_set_updated_at
before update on public.contact_points
for each row execute function public.set_updated_at();


-- ============================================================================
-- 3. OPPORTUNITIES
-- One commercial enquiry / lead instance.
--
-- A prospect may have multiple opportunities over time.
-- ============================================================================

create table public.opportunities (
    opportunity_id uuid primary key default gen_random_uuid(),

    prospect_id uuid not null
        references public.prospects(prospect_id),

    predecessor_opportunity_id uuid,

    lead_type text not null default 'UNKNOWN'
        check (
            lead_type in (
                'PROFESSIONAL_TRAINING',
                'BUSINESS_PARTNERSHIP',
                'GENERAL_SERVICE',
                'UNKNOWN'
            )
        ),

    source_channel text not null
        check (
            source_channel in (
                'WEB_CALL',
                'PHONE_CALL',
                'MISSED_CALL_RECOVERY',
                'SMS',
                'REACTIVATION',
                'MANUAL',
                'CRM_IMPORT',
                'OTHER'
            )
        ),

    source_event_key text,

    location_code text not null default 'UNKNOWN'
        check (
            location_code in (
                'BRISBANE',
                'MELBOURNE',
                'SYDNEY',
                'PERTH',
                'OTHER',
                'UNKNOWN'
            )
        ),

    lifecycle_state text not null default 'NEW'
        check (
            lifecycle_state in (
                'NEW',
                'ENGAGED',
                'QUALIFYING',
                'QUALIFIED',
                'BOOKING_READY',
                'BOOKED',
                'DORMANT',
                'WON',
                'LOST',
                'CLOSED'
            )
        ),

    qualification_state text not null default 'NOT_STARTED'
        check (
            qualification_state in (
                'NOT_STARTED',
                'IN_PROGRESS',
                'QUALIFIED',
                'REVIEW_REQUIRED',
                'DISQUALIFIED'
            )
        ),

    current_intent text not null default 'UNKNOWN'
        check (
            current_intent in (
                'PROFESSIONAL_TRAINING',
                'BUSINESS_PARTNERSHIP',
                'GENERAL_SERVICE',
                'UNKNOWN'
            )
        ),

    current_objection text,
    assigned_owner text,

    final_outcome text
        check (
            final_outcome is null
            or final_outcome in (
                'WON',
                'LOST',
                'DORMANT',
                'DUPLICATE',
                'INELIGIBLE',
                'WITHDRAWN',
                'OTHER'
            )
        ),

    last_activity_at timestamptz,
    last_contact_at timestamptz,
    next_action_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint opportunities_id_prospect_unique
        unique (opportunity_id, prospect_id),

    constraint opportunities_no_self_predecessor
        check (
            predecessor_opportunity_id is null
            or predecessor_opportunity_id <> opportunity_id
        ),

    constraint opportunities_predecessor_same_prospect
        foreign key (predecessor_opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id)
);

create unique index opportunities_source_event_unique_idx
    on public.opportunities(source_channel, source_event_key)
    where source_event_key is not null;

create index opportunities_prospect_idx
    on public.opportunities(prospect_id);

create index opportunities_lifecycle_idx
    on public.opportunities(lifecycle_state);

create index opportunities_qualification_idx
    on public.opportunities(qualification_state);

create index opportunities_next_action_idx
    on public.opportunities(next_action_at)
    where next_action_at is not null;

create trigger opportunities_set_updated_at
before update on public.opportunities
for each row execute function public.set_updated_at();


-- ============================================================================
-- 4. CONTACT ELIGIBILITY
-- Current deterministic permission/control state by prospect/contact/channel.
--
-- This is NOT opportunity lifecycle.
-- ============================================================================

create table public.contact_eligibility (
    eligibility_id uuid primary key default gen_random_uuid(),

    prospect_id uuid not null
        references public.prospects(prospect_id),

    contact_point_id uuid,

    channel text not null
        check (
            channel in (
                'VOICE',
                'SMS',
                'EMAIL'
            )
        ),

    purpose text not null
        check (
            purpose in (
                'INBOUND_RESPONSE',
                'OUTBOUND_SALES',
                'REACTIVATION',
                'APPOINTMENT_RECOVERY'
            )
        ),

    eligibility_state text not null default 'REVIEW_REQUIRED'
        check (
            eligibility_state in (
                'ELIGIBLE',
                'REVIEW_REQUIRED',
                'INELIGIBLE'
            )
        ),

    dnd boolean not null default false,

    consent_basis text not null default 'UNKNOWN'
        check (
            consent_basis in (
                'EXPLICIT_CONSENT',
                'INBOUND_REQUEST',
                'EXISTING_RELATIONSHIP',
                'BUSINESS_RULE_APPROVED',
                'NOT_REQUIRED',
                'UNKNOWN',
                'REVOKED'
            )
        ),

    provenance_source text,
    provenance_reference text,
    reason_code text,

    effective_at timestamptz not null default now(),
    expires_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint contact_eligibility_contact_matches_prospect
        foreign key (contact_point_id, prospect_id)
        references public.contact_points(contact_point_id, prospect_id),

    constraint contact_eligibility_expiry_order
        check (
            expires_at is null
            or expires_at >= effective_at
        ),

    constraint contact_eligibility_dnd_consistency
        check (
            dnd = false
            or eligibility_state = 'INELIGIBLE'
        ),

    constraint contact_eligibility_revoked_consistency
        check (
            consent_basis <> 'REVOKED'
            or eligibility_state = 'INELIGIBLE'
        )
);

create unique index contact_eligibility_prospect_scope_unique_idx
    on public.contact_eligibility(prospect_id, channel, purpose)
    where contact_point_id is null;

create unique index contact_eligibility_contact_scope_unique_idx
    on public.contact_eligibility(
        prospect_id,
        contact_point_id,
        channel,
        purpose
    )
    where contact_point_id is not null;

create index contact_eligibility_state_idx
    on public.contact_eligibility(eligibility_state, channel, purpose);

create trigger contact_eligibility_set_updated_at
before update on public.contact_eligibility
for each row execute function public.set_updated_at();


-- ============================================================================
-- 5. CONSENT EVENTS
-- Append-only provenance/history for contact permission changes.
-- ============================================================================

create table public.consent_events (
    consent_event_id uuid primary key default gen_random_uuid(),

    prospect_id uuid not null
        references public.prospects(prospect_id),

    contact_point_id uuid,

    channel text not null
        check (
            channel in (
                'VOICE',
                'SMS',
                'EMAIL'
            )
        ),

    purpose text
        check (
            purpose is null
            or purpose in (
                'INBOUND_RESPONSE',
                'OUTBOUND_SALES',
                'REACTIVATION',
                'APPOINTMENT_RECOVERY'
            )
        ),

    action text not null
        check (
            action in (
                'CONSENT_GRANTED',
                'CONSENT_REVOKED',
                'OPT_IN',
                'OPT_OUT',
                'DND_SET',
                'DND_CLEARED',
                'ELIGIBILITY_REVIEWED'
            )
        ),

    source text not null,
    source_event_id text,

    evidence_reference text,
    evidence_summary text,

    occurred_at timestamptz not null,
    recorded_at timestamptz not null default now(),

    constraint consent_events_contact_matches_prospect
        foreign key (contact_point_id, prospect_id)
        references public.contact_points(contact_point_id, prospect_id)
);

create unique index consent_events_source_event_unique_idx
    on public.consent_events(source, source_event_id)
    where source_event_id is not null;

create index consent_events_prospect_idx
    on public.consent_events(prospect_id, occurred_at desc);


-- ============================================================================
-- 6. CALLS
-- Canonical voice-call records.
-- ============================================================================

create table public.calls (
    call_id uuid primary key default gen_random_uuid(),

    correlation_id uuid not null default gen_random_uuid(),

    prospect_id uuid
        references public.prospects(prospect_id),

    opportunity_id uuid,

    provider text not null
        check (
            provider in (
                'RETELL',
                'TWILIO',
                'OTHER'
            )
        ),

    telephony_provider text,

    provider_call_id text not null,

    call_type text not null
        check (
            call_type in (
                'WEB',
                'PHONE',
                'MISSED_RECOVERY',
                'REACTIVATION',
                'OTHER'
            )
        ),

    direction text not null
        check (
            direction in (
                'INBOUND',
                'OUTBOUND'
            )
        ),

    status text not null default 'REGISTERED'
        check (
            status in (
                'REGISTERED',
                'ACTIVE',
                'ENDED',
                'ANALYSIS_PENDING',
                'ANALYZED',
                'POST_PROCESSED',
                'FAILED'
            )
        ),

    disconnection_reason text,

    started_at timestamptz,
    ended_at timestamptz,
    duration_ms integer
        check (
            duration_ms is null
            or duration_ms >= 0
        ),

    transcript_reference text,
    knowledge_retrieval_reference text,

    summary text,

    detected_intent text
        check (
            detected_intent is null
            or detected_intent in (
                'PROFESSIONAL_TRAINING',
                'BUSINESS_PARTNERSHIP',
                'GENERAL_SERVICE',
                'UNKNOWN'
            )
        ),

    qualification_result text
        check (
            qualification_result is null
            or qualification_result in (
                'QUALIFIED',
                'REVIEW_REQUIRED',
                'UNQUALIFIED',
                'UNKNOWN'
            )
        ),

    appointment_result text
        check (
            appointment_result is null
            or appointment_result in (
                'NOT_DISCUSSED',
                'AVAILABILITY_CHECKED',
                'BOOKED',
                'SLOT_UNAVAILABLE',
                'FAILED',
                'HUMAN_REQUIRED'
            )
        ),

    post_call_analysis jsonb,
    error_state text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint calls_opportunity_requires_prospect
        check (
            opportunity_id is null
            or prospect_id is not null
        ),

    constraint calls_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint calls_time_order
        check (
            ended_at is null
            or started_at is null
            or ended_at >= started_at
        )
);

create unique index calls_provider_call_unique_idx
    on public.calls(provider, provider_call_id);

create index calls_prospect_idx
    on public.calls(prospect_id);

create index calls_opportunity_idx
    on public.calls(opportunity_id);

create index calls_status_idx
    on public.calls(status);

create index calls_started_at_idx
    on public.calls(started_at desc);

create trigger calls_set_updated_at
before update on public.calls
for each row execute function public.set_updated_at();


-- ============================================================================
-- 7. CONVERSATIONS
-- Cross-channel conversational sessions.
-- ============================================================================

create table public.conversations (
    conversation_id uuid primary key default gen_random_uuid(),

    prospect_id uuid
        references public.prospects(prospect_id),

    opportunity_id uuid,

    call_id uuid
        references public.calls(call_id),

    channel text not null
        check (
            channel in (
                'VOICE',
                'SMS',
                'CHAT',
                'EMAIL'
            )
        ),

    provider text not null,

    external_conversation_id text,

    state text not null default 'ACTIVE'
        check (
            state in (
                'ACTIVE',
                'ENDED',
                'HUMAN_OWNED',
                'CLOSED'
            )
        ),

    started_at timestamptz not null default now(),
    ended_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint conversations_opportunity_requires_prospect
        check (
            opportunity_id is null
            or prospect_id is not null
        ),

    constraint conversations_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint conversations_time_order
        check (
            ended_at is null
            or ended_at >= started_at
        )
);

create unique index conversations_external_unique_idx
    on public.conversations(provider, external_conversation_id)
    where external_conversation_id is not null;

create index conversations_prospect_idx
    on public.conversations(prospect_id);

create index conversations_opportunity_idx
    on public.conversations(opportunity_id);

create index conversations_state_idx
    on public.conversations(state);

create trigger conversations_set_updated_at
before update on public.conversations
for each row execute function public.set_updated_at();


-- ============================================================================
-- 8. MESSAGES
-- Append-only individual message/turn records.
-- ============================================================================

create table public.messages (
    message_id uuid primary key default gen_random_uuid(),

    conversation_id uuid not null
        references public.conversations(conversation_id),

    prospect_id uuid
        references public.prospects(prospect_id),

    opportunity_id uuid,

    provider text not null,
    provider_message_id text,

    channel text not null
        check (
            channel in (
                'VOICE',
                'SMS',
                'CHAT',
                'EMAIL'
            )
        ),

    direction text not null
        check (
            direction in (
                'INBOUND',
                'OUTBOUND',
                'INTERNAL'
            )
        ),

    role text not null
        check (
            role in (
                'CALLER',
                'AI_ASSISTANT',
                'HUMAN',
                'SYSTEM'
            )
        ),

    body text not null,

    structured_content jsonb,

    occurred_at timestamptz not null,
    created_at timestamptz not null default now(),

    constraint messages_opportunity_requires_prospect
        check (
            opportunity_id is null
            or prospect_id is not null
        ),

    constraint messages_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id)
);

create unique index messages_provider_message_unique_idx
    on public.messages(provider, provider_message_id)
    where provider_message_id is not null;

create index messages_conversation_idx
    on public.messages(conversation_id, occurred_at);

create index messages_prospect_idx
    on public.messages(prospect_id);


-- ============================================================================
-- 9. APPOINTMENTS
-- Local booking mirror; Cal.com remains provider booking truth.
-- ============================================================================

create table public.appointments (
    appointment_id uuid primary key default gen_random_uuid(),

    prospect_id uuid not null
        references public.prospects(prospect_id),

    opportunity_id uuid not null,

    provider text not null default 'CAL_COM'
        check (
            provider in (
                'CAL_COM',
                'OTHER'
            )
        ),

    booking_uid text,
    booking_request_id text,

    event_type_code text not null,
    provider_event_type_id text,

    start_at_utc timestamptz,
    end_at_utc timestamptz,

    attendee_timezone text,

    status text not null default 'PROPOSED'
        check (
            status in (
                'PROPOSED',
                'CREATE_PENDING',
                'CONFIRMED',
                'RESCHEDULE_PENDING',
                'CANCEL_PENDING',
                'CANCELLED',
                'COMPLETED',
                'NO_SHOW',
                'CREATE_FAILED'
            )
        ),

    provider_status text,

    reschedule_parent_id uuid
        references public.appointments(appointment_id),

    booking_metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint appointments_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint appointments_no_self_reschedule
        check (
            reschedule_parent_id is null
            or reschedule_parent_id <> appointment_id
        ),

    constraint appointments_time_order
        check (
            end_at_utc is null
            or start_at_utc is null
            or end_at_utc > start_at_utc
        )
);

create unique index appointments_provider_booking_unique_idx
    on public.appointments(provider, booking_uid)
    where booking_uid is not null;

create unique index appointments_booking_request_unique_idx
    on public.appointments(booking_request_id)
    where booking_request_id is not null;

create index appointments_opportunity_idx
    on public.appointments(opportunity_id);

create index appointments_status_idx
    on public.appointments(status);

create index appointments_start_idx
    on public.appointments(start_at_utc)
    where start_at_utc is not null;

create trigger appointments_set_updated_at
before update on public.appointments
for each row execute function public.set_updated_at();


-- ============================================================================
-- 10. HUMAN HANDOFFS
-- First-class escalation/ownership object.
-- ============================================================================

create table public.human_handoffs (
    handoff_id uuid primary key default gen_random_uuid(),

    request_id text not null default gen_random_uuid()::text,

    prospect_id uuid not null
        references public.prospects(prospect_id),

    opportunity_id uuid not null,

    call_id uuid
        references public.calls(call_id),

    conversation_id uuid
        references public.conversations(conversation_id),

    source_channel text not null
        check (
            source_channel in (
                'VOICE',
                'SMS',
                'CHAT',
                'EMAIL',
                'SYSTEM'
            )
        ),

    reason_code text not null
        check (
            reason_code in (
                'EXPLICIT_HUMAN_REQUEST',
                'SENSITIVE_OR_CLINICAL',
                'LOW_CONFIDENCE',
                'UNSUPPORTED_KNOWLEDGE',
                'HIGH_VALUE_OPPORTUNITY',
                'CALLER_FRUSTRATION',
                'BOOKING_FAILURE',
                'TOOL_FAILURE',
                'CONFLICTING_INTENT',
                'OUT_OF_SCOPE'
            )
        ),

    priority text not null default 'NORMAL'
        check (
            priority in (
                'LOW',
                'NORMAL',
                'HIGH',
                'CRITICAL'
            )
        ),

    requested_by text not null
        check (
            requested_by in (
                'CALLER',
                'AI',
                'SYSTEM',
                'HUMAN'
            )
        ),

    requested_at timestamptz not null default now(),

    caller_name text,
    location_code text
        check (
            location_code is null
            or location_code in (
                'BRISBANE',
                'MELBOURNE',
                'SYDNEY',
                'PERTH',
                'OTHER',
                'UNKNOWN'
            )
        ),

    primary_intent text
        check (
            primary_intent is null
            or primary_intent in (
                'PROFESSIONAL_TRAINING',
                'BUSINESS_PARTNERSHIP',
                'GENERAL_SERVICE',
                'UNKNOWN'
            )
        ),

    qualification_state text,
    main_objection text,

    conversation_summary text,

    questions_asked jsonb not null default '[]'::jsonb,
    topics_answered jsonb not null default '[]'::jsonb,
    unresolved_questions jsonb not null default '[]'::jsonb,

    sensitive_topic_detected boolean not null default false,
    caller_explicitly_requested_human boolean not null default false,

    recommended_next_action text,

    transfer_mode text not null default 'QUEUE_ONLY'
        check (
            transfer_mode in (
                'NONE',
                'QUEUE_ONLY',
                'WARM',
                'COLD'
            )
        ),

    transfer_destination_alias text,

    transfer_result text not null default 'NOT_ATTEMPTED'
        check (
            transfer_result in (
                'NOT_ATTEMPTED',
                'QUEUED',
                'STARTED',
                'BRIDGED',
                'FAILED',
                'CANCELLED',
                'ENDED'
            )
        ),

    assigned_owner text,

    handoff_status text not null default 'OPEN'
        check (
            handoff_status in (
                'OPEN',
                'CLAIMED',
                'RESOLVED',
                'CANCELLED'
            )
        ),

    claimed_at timestamptz,
    resolved_at timestamptz,
    resolution_notes text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint human_handoffs_request_unique
        unique (request_id),

    constraint human_handoffs_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint human_handoffs_questions_array
        check (jsonb_typeof(questions_asked) = 'array'),

    constraint human_handoffs_topics_array
        check (jsonb_typeof(topics_answered) = 'array'),

    constraint human_handoffs_unresolved_array
        check (jsonb_typeof(unresolved_questions) = 'array')
);

create index human_handoffs_opportunity_idx
    on public.human_handoffs(opportunity_id);

create unique index human_handoffs_active_call_reason_unique_idx
    on public.human_handoffs(call_id, reason_code)
    where call_id is not null
      and handoff_status in ('OPEN', 'CLAIMED');

create unique index human_handoffs_active_conversation_reason_unique_idx
    on public.human_handoffs(conversation_id, reason_code)
    where conversation_id is not null
      and handoff_status in ('OPEN', 'CLAIMED');

create index human_handoffs_open_idx
    on public.human_handoffs(handoff_status, priority, requested_at)
    where handoff_status in ('OPEN', 'CLAIMED');

create trigger human_handoffs_set_updated_at
before update on public.human_handoffs
for each row execute function public.set_updated_at();


-- ============================================================================
-- 11. AI DECISIONS
-- Versioned structured AI inference.
-- AI inference is not authoritative business state.
-- ============================================================================

create table public.ai_decisions (
    decision_id uuid primary key default gen_random_uuid(),

    prospect_id uuid
        references public.prospects(prospect_id),

    opportunity_id uuid,

    call_id uuid
        references public.calls(call_id),

    conversation_id uuid
        references public.conversations(conversation_id),

    decision_type text not null
        check (
            decision_type in (
                'INTENT_INTERPRETATION',
                'POST_CALL_ANALYSIS',
                'SMS_INTERPRETATION',
                'SEGMENTATION',
                'OTHER'
            )
        ),

    provider text not null,
    model text,

    schema_name text not null,
    schema_version text not null,
    prompt_version text,

    input_hash text,

    raw_output jsonb,
    validated_output jsonb,

    confidence numeric(5,4)
        check (
            confidence is null
            or (
                confidence >= 0
                and confidence <= 1
            )
        ),

    validation_state text not null
        check (
            validation_state in (
                'VALID',
                'INVALID',
                'REVIEW_REQUIRED'
            )
        ),

    validation_errors jsonb not null default '[]'::jsonb,
    knowledge_source_codes text[] not null default array[]::text[],

    created_at timestamptz not null default now(),

    constraint ai_decisions_opportunity_requires_prospect
        check (
            opportunity_id is null
            or prospect_id is not null
        ),

    constraint ai_decisions_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint ai_decisions_validation_errors_array
        check (jsonb_typeof(validation_errors) = 'array')
);

create index ai_decisions_opportunity_idx
    on public.ai_decisions(opportunity_id, created_at desc);

create index ai_decisions_call_idx
    on public.ai_decisions(call_id, created_at desc);

create index ai_decisions_type_idx
    on public.ai_decisions(decision_type, created_at desc);


-- ============================================================================
-- 12. KNOWLEDGE SOURCES
-- Canonical version metadata for repository-managed approved knowledge.
-- ============================================================================

create table public.knowledge_sources (
    knowledge_source_id uuid primary key default gen_random_uuid(),

    source_code text not null,
    title text not null,
    version text not null,

    approval_status text not null default 'DRAFT'
        check (
            approval_status in (
                'DRAFT',
                'APPROVED',
                'RETIRED'
            )
        ),

    effective_at timestamptz,
    retired_at timestamptz,

    approved_topics text[] not null default array[]::text[],
    restricted_topics text[] not null default array[]::text[],

    content_hash text not null,
    repository_path text not null,

    provider_reference text,
    published_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint knowledge_sources_code_version_unique
        unique (source_code, version),

    constraint knowledge_sources_retirement_order
        check (
            retired_at is null
            or effective_at is null
            or retired_at >= effective_at
        )
);

create index knowledge_sources_status_idx
    on public.knowledge_sources(approval_status);

create index knowledge_sources_code_idx
    on public.knowledge_sources(source_code);

create trigger knowledge_sources_set_updated_at
before update on public.knowledge_sources
for each row execute function public.set_updated_at();


-- ============================================================================
-- 13. TOOL EXECUTIONS
-- Idempotency + audit for Retell/backend tool calls.
-- ============================================================================

create table public.tool_executions (
    tool_execution_id uuid primary key default gen_random_uuid(),

    correlation_id uuid not null default gen_random_uuid(),

    prospect_id uuid
        references public.prospects(prospect_id),

    opportunity_id uuid,

    call_id uuid
        references public.calls(call_id),

    provider text not null,
    provider_tool_call_id text,

    tool_name text not null,

    idempotency_key text not null,
    request_hash text not null,

    request_payload jsonb not null default '{}'::jsonb,
    response_payload jsonb,

    outcome text not null default 'PENDING'
        check (
            outcome in (
                'PENDING',
                'SUCCEEDED',
                'FAILED',
                'REPLAYED',
                'REJECTED'
            )
        ),

    retry_count integer not null default 0
        check (retry_count >= 0),

    error_code text,

    started_at timestamptz not null default now(),
    completed_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint tool_executions_idempotency_unique
        unique (idempotency_key),

    constraint tool_executions_opportunity_requires_prospect
        check (
            opportunity_id is null
            or prospect_id is not null
        ),

    constraint tool_executions_opportunity_matches_prospect
        foreign key (opportunity_id, prospect_id)
        references public.opportunities(opportunity_id, prospect_id),

    constraint tool_executions_time_order
        check (
            completed_at is null
            or completed_at >= started_at
        )
);

create unique index tool_executions_provider_call_unique_idx
    on public.tool_executions(provider, provider_tool_call_id)
    where provider_tool_call_id is not null;

create index tool_executions_call_idx
    on public.tool_executions(call_id, started_at desc);

create index tool_executions_outcome_idx
    on public.tool_executions(outcome);

create trigger tool_executions_set_updated_at
before update on public.tool_executions
for each row execute function public.set_updated_at();


-- ============================================================================
-- 14. RAW PROVIDER EVENTS
-- Append-only raw external event envelope.
-- Processing state belongs to the outbox/canonical event path.
-- ============================================================================

create table public.raw_provider_events (
    raw_provider_event_id uuid primary key default gen_random_uuid(),

    correlation_id uuid not null default gen_random_uuid(),

    provider text not null,
    event_type text not null,
    event_key text not null,

    payload_hash text not null,
    payload jsonb not null,

    signature_valid boolean,

    received_at timestamptz not null default now(),

    constraint raw_provider_events_provider_key_unique
        unique (provider, event_key)
);

create index raw_provider_events_type_idx
    on public.raw_provider_events(provider, event_type, received_at desc);

create index raw_provider_events_received_idx
    on public.raw_provider_events(received_at desc);


-- ============================================================================
-- 15. OUTBOX EVENTS
-- Reliable async bridge from application/database events to n8n/workers.
-- ============================================================================

create table public.outbox_events (
    outbox_event_id uuid primary key default gen_random_uuid(),

    event_key text not null,
    event_type text not null,

    aggregate_type text,
    aggregate_id uuid,

    source_raw_provider_event_id uuid
        references public.raw_provider_events(raw_provider_event_id),

    correlation_id uuid not null default gen_random_uuid(),

    payload jsonb not null default '{}'::jsonb,

    status text not null default 'PENDING'
        check (
            status in (
                'PENDING',
                'PROCESSING',
                'PROCESSED',
                'FAILED',
                'DEAD_LETTER'
            )
        ),

    available_at timestamptz not null default now(),

    locked_at timestamptz,
    locked_by text,

    attempts integer not null default 0
        check (attempts >= 0),

    max_attempts integer not null default 5
        check (max_attempts >= 1),

    last_error text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint outbox_events_event_key_unique
        unique (event_key),

    constraint outbox_attempt_limit_consistency
        check (attempts <= max_attempts)
);

create index outbox_events_dispatch_idx
    on public.outbox_events(status, available_at)
    where status in ('PENDING', 'FAILED');

create index outbox_events_correlation_idx
    on public.outbox_events(correlation_id);

create trigger outbox_events_set_updated_at
before update on public.outbox_events
for each row execute function public.set_updated_at();


-- ============================================================================
-- 16. AUDIT EVENTS
-- Append-only business-state audit trail.
-- ============================================================================

create table public.audit_events (
    audit_event_id uuid primary key default gen_random_uuid(),

    correlation_id uuid not null default gen_random_uuid(),

    actor_type text not null
        check (
            actor_type in (
                'SYSTEM',
                'AI',
                'HUMAN',
                'PROVIDER',
                'WORKFLOW'
            )
        ),

    actor_id text,

    entity_type text not null,
    entity_id uuid,

    action text not null,
    reason_code text,

    before_state jsonb,
    after_state jsonb,
    metadata jsonb not null default '{}'::jsonb,

    occurred_at timestamptz not null default now()
);

create index audit_events_entity_idx
    on public.audit_events(entity_type, entity_id, occurred_at desc);

create index audit_events_correlation_idx
    on public.audit_events(correlation_id);

create index audit_events_occurred_idx
    on public.audit_events(occurred_at desc);


-- ============================================================================
-- 17. FAILURE EVENTS
-- Operational exception/error state.
-- ============================================================================

create table public.failure_events (
    failure_event_id uuid primary key default gen_random_uuid(),

    correlation_id uuid not null default gen_random_uuid(),

    provider text,
    stage text not null,

    error_class text not null
        check (
            error_class in (
                'VALIDATION',
                'AUTHENTICATION',
                'DATABASE',
                'VOICE_PROVIDER',
                'AI_PROVIDER',
                'KNOWLEDGE',
                'BOOKING_PROVIDER',
                'TELEPHONY',
                'SMS_PROVIDER',
                'NOTIFICATION',
                'WEBHOOK',
                'STATE_CONFLICT'
            )
        ),

    severity text not null default 'ERROR'
        check (
            severity in (
                'INFO',
                'WARNING',
                'ERROR',
                'CRITICAL'
            )
        ),

    retryable boolean not null default false,

    error_code text,
    sanitized_message text not null,

    entity_type text,
    entity_id uuid,

    attempt_count integer not null default 1
        check (attempt_count >= 1),

    first_seen_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),

    resolution_status text not null default 'OPEN'
        check (
            resolution_status in (
                'OPEN',
                'RETRY_SCHEDULED',
                'RESOLVED',
                'IGNORED',
                'DEAD_LETTER'
            )
        ),

    resolution_notes text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint failure_events_seen_order
        check (last_seen_at >= first_seen_at)
);

create index failure_events_open_idx
    on public.failure_events(resolution_status, severity, last_seen_at desc)
    where resolution_status <> 'RESOLVED';

create index failure_events_correlation_idx
    on public.failure_events(correlation_id);

create trigger failure_events_set_updated_at
before update on public.failure_events
for each row execute function public.set_updated_at();


-- ============================================================================
-- 18. CRM LINKS
-- CRM-agnostic external mapping.
--
-- PostgreSQL remains the demo CRM.
-- These links exist only when an external CRM adapter is introduced.
-- ============================================================================

create table public.crm_links (
    crm_link_id uuid primary key default gen_random_uuid(),

    internal_entity_type text not null
        check (
            internal_entity_type in (
                'PROSPECT',
                'OPPORTUNITY',
                'APPOINTMENT'
            )
        ),

    internal_entity_id uuid not null,

    crm_provider text not null
        check (
            crm_provider in (
                'GOHIGHLEVEL',
                'HUBSPOT',
                'OTHER'
            )
        ),

    external_type text not null,
    external_id text not null,

    sync_status text not null default 'NOT_SYNCED'
        check (
            sync_status in (
                'NOT_SYNCED',
                'PENDING',
                'SYNCED',
                'FAILED',
                'REVIEW_REQUIRED'
            )
        ),

    last_synced_at timestamptz,

    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint crm_links_external_unique
        unique (
            crm_provider,
            external_type,
            external_id
        ),

    constraint crm_links_internal_provider_unique
        unique (
            internal_entity_type,
            internal_entity_id,
            crm_provider,
            external_type
        )
);

create index crm_links_internal_idx
    on public.crm_links(internal_entity_type, internal_entity_id);

create index crm_links_sync_status_idx
    on public.crm_links(sync_status);

create trigger crm_links_set_updated_at
before update on public.crm_links
for each row execute function public.set_updated_at();


-- ============================================================================
-- ROW LEVEL SECURITY
--
-- No public/client database access exists yet.
-- Edge Functions/application services will use controlled server credentials.
-- UI-specific authenticated policies will be introduced later with the
-- operator interface rather than exposing tables prematurely.
-- ============================================================================

alter table public.prospects enable row level security;
alter table public.contact_points enable row level security;
alter table public.opportunities enable row level security;
alter table public.contact_eligibility enable row level security;
alter table public.consent_events enable row level security;
alter table public.calls enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.appointments enable row level security;
alter table public.human_handoffs enable row level security;
alter table public.ai_decisions enable row level security;
alter table public.knowledge_sources enable row level security;
alter table public.tool_executions enable row level security;
alter table public.raw_provider_events enable row level security;
alter table public.outbox_events enable row level security;
alter table public.audit_events enable row level security;
alter table public.failure_events enable row level security;
alter table public.crm_links enable row level security;


-- ============================================================================
-- CLIENT ROLE PRIVILEGES
-- Explicitly deny client/API roles until real UI policies are designed.
-- ============================================================================

revoke all on table public.prospects from anon, authenticated;
revoke all on table public.contact_points from anon, authenticated;
revoke all on table public.opportunities from anon, authenticated;
revoke all on table public.contact_eligibility from anon, authenticated;
revoke all on table public.consent_events from anon, authenticated;
revoke all on table public.calls from anon, authenticated;
revoke all on table public.conversations from anon, authenticated;
revoke all on table public.messages from anon, authenticated;
revoke all on table public.appointments from anon, authenticated;
revoke all on table public.human_handoffs from anon, authenticated;
revoke all on table public.ai_decisions from anon, authenticated;
revoke all on table public.knowledge_sources from anon, authenticated;
revoke all on table public.tool_executions from anon, authenticated;
revoke all on table public.raw_provider_events from anon, authenticated;
revoke all on table public.outbox_events from anon, authenticated;
revoke all on table public.audit_events from anon, authenticated;
revoke all on table public.failure_events from anon, authenticated;
revoke all on table public.crm_links from anon, authenticated;


-- ============================================================================
-- SERVER ROLE PRIVILEGES
--
-- Mutable operational tables:
-- SELECT / INSERT / UPDATE / DELETE
--
-- Historical append-only tables:
-- SELECT / INSERT only
-- ============================================================================

grant select, insert, update, delete
on table
    public.prospects,
    public.contact_points,
    public.opportunities,
    public.contact_eligibility,
    public.calls,
    public.conversations,
    public.appointments,
    public.human_handoffs,
    public.knowledge_sources,
    public.tool_executions,
    public.outbox_events,
    public.failure_events,
    public.crm_links
to service_role;

revoke all
on table
    public.consent_events,
    public.messages,
    public.ai_decisions,
    public.raw_provider_events,
    public.audit_events
from service_role;

grant select, insert
on table
    public.consent_events,
    public.messages,
    public.ai_decisions,
    public.raw_provider_events,
    public.audit_events
to service_role;

-- ============================================================================
-- END MIGRATION 001
-- ============================================================================