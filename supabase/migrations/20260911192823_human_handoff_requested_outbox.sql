-- ============================================================================
-- Phase 5C: Human handoff requested outbox event
--
-- Purpose:
--   Emit reliable asynchronous work whenever a new authoritative
--   human_handoffs row is created.
--
-- Authority rules:
--   - PostgreSQL owns authoritative handoff state.
--   - The outbox event is created in the same transaction as the handoff.
--   - Replayed/equivalent handoff requests that reuse an existing handoff
--     do not create another event because this trigger fires only on INSERT.
--   - n8n remains an asynchronous consumer only.
--   - No Retell, booking, eligibility, DND, or lifecycle state is mutated here.
-- ============================================================================


create or replace function public.enqueue_human_handoff_requested_v1()
returns trigger
language plpgsql
security invoker
set search_path = public
as $function$
declare
    v_event_key text;
begin
    --------------------------------------------------------------------------
    -- One deterministic event identity per newly-created handoff.
    --------------------------------------------------------------------------

    v_event_key :=
        'human_handoff:' ||
        new.handoff_id::text ||
        ':requested';


    --------------------------------------------------------------------------
    -- Persist asynchronous work in the same transaction as the handoff.
    --
    -- source_raw_provider_event_id intentionally remains NULL because this
    -- is an internal domain event, not a raw external provider event.
    --
    -- correlation_id uses the outbox table's server-generated UUID default.
    --------------------------------------------------------------------------

    insert into public.outbox_events (
        event_key,
        event_type,
        aggregate_type,
        aggregate_id,
        payload
    )
    values (
        v_event_key,
        'HUMAN_HANDOFF_REQUESTED',
        'HUMAN_HANDOFF',
        new.handoff_id,
        jsonb_build_object(
            'handoff_id',
            new.handoff_id,

            'call_id',
            new.call_id,

            'conversation_id',
            new.conversation_id,

            'prospect_id',
            new.prospect_id,

            'opportunity_id',
            new.opportunity_id,

            'source_channel',
            new.source_channel,

            'reason_code',
            new.reason_code,

            'priority',
            new.priority,

            'requested_by',
            new.requested_by,

            'caller_explicitly_requested_human',
            new.caller_explicitly_requested_human,

            'transfer_mode',
            new.transfer_mode,

            'handoff_status',
            new.handoff_status,

            'requested_at',
            new.requested_at
        )
    );

    return new;
end;
$function$;


drop trigger if exists
human_handoffs_enqueue_requested_outbox
on public.human_handoffs;


create trigger human_handoffs_enqueue_requested_outbox
after insert on public.human_handoffs
for each row
execute function public.enqueue_human_handoff_requested_v1();


comment on function public.enqueue_human_handoff_requested_v1()
is
'Phase 5C transactional outbox bridge for newly-created human handoffs. Emits exactly one HUMAN_HANDOFF_REQUESTED event for each authoritative human_handoffs insert.';


revoke all
on function public.enqueue_human_handoff_requested_v1()
from public;

revoke all
on function public.enqueue_human_handoff_requested_v1()
from anon;

revoke all
on function public.enqueue_human_handoff_requested_v1()
from authenticated;