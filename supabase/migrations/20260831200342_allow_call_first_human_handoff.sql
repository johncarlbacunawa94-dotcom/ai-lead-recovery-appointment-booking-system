-- ============================================================================
-- Migration 002: Allow call-first human handoff
--
-- A caller may request a human or trigger a sensitive-topic escalation before
-- identity resolution or opportunity creation has occurred.
--
-- Handoff must therefore be able to exist against a call/conversation alone.
-- ============================================================================

alter table public.human_handoffs
    alter column prospect_id drop not null;

alter table public.human_handoffs
    alter column opportunity_id drop not null;

alter table public.human_handoffs
    add constraint human_handoffs_context_required
    check (
        call_id is not null
        or conversation_id is not null
        or opportunity_id is not null
    );

-- If opportunity_id exists, prospect_id must also exist.
alter table public.human_handoffs
    add constraint human_handoffs_opportunity_requires_prospect
    check (
        opportunity_id is null
        or prospect_id is not null
    );

-- ============================================================================
-- END MIGRATION 002
-- ============================================================================