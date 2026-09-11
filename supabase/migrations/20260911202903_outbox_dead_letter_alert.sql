-- ============================================================================
-- Phase 5D: Outbox dead-letter alert bridge
--
-- Purpose:
--   When an asynchronous outbox event becomes DEAD_LETTER, enqueue exactly one
--   separate operator-alert work item.
--
-- Authority rules:
--   - PostgreSQL remains authoritative for outbox processing state.
--   - Alert creation occurs transactionally with the DEAD_LETTER transition.
--   - The original outbox event is never mutated by the alert worker.
--   - Alert events cannot recursively generate more dead-letter alerts.
--   - Existing claim / complete / fail worker RPCs remain unchanged.
-- ============================================================================

create or replace function public.enqueue_outbox_dead_letter_alert_v1()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_alert_event_key text;
begin
    if new.status <> 'DEAD_LETTER' then
        return new;
    end if;

    -- Prevent recursive dead-letter alert generation.
    if new.event_type = 'OUTBOX_DEAD_LETTER_ALERT' then
        return new;
    end if;

    -- Exactly one alert event per original dead-lettered outbox event.
    v_alert_event_key :=
        'outbox_dead_letter:' ||
        new.outbox_event_id::text ||
        ':alert';

    insert into public.outbox_events (
        event_key,
        event_type,
        aggregate_type,
        aggregate_id,
        correlation_id,
        payload
    )
    values (
        v_alert_event_key,
        'OUTBOX_DEAD_LETTER_ALERT',
        'OUTBOX_EVENT',
        new.outbox_event_id,
        new.correlation_id,
        jsonb_build_object(
            'original_outbox_event_id',
            new.outbox_event_id,
            'original_event_key',
            new.event_key,
            'original_event_type',
            new.event_type,
            'original_aggregate_type',
            new.aggregate_type,
            'original_aggregate_id',
            new.aggregate_id,
            'attempts',
            new.attempts,
            'max_attempts',
            new.max_attempts,
            'last_error',
            new.last_error,
            'dead_lettered_at',
            new.updated_at
        )
    )
    on conflict on constraint outbox_events_event_key_unique
    do nothing;

    return new;
end;
$function$;

drop trigger if exists outbox_events_enqueue_dead_letter_alert
on public.outbox_events;

create trigger outbox_events_enqueue_dead_letter_alert
after update of status on public.outbox_events
for each row
when (
    old.status is distinct from 'DEAD_LETTER'
    and new.status = 'DEAD_LETTER'
)
execute function public.enqueue_outbox_dead_letter_alert_v1();

comment on function public.enqueue_outbox_dead_letter_alert_v1()
is 'Phase 5D transactional bridge that enqueues exactly one OUTBOX_DEAD_LETTER_ALERT when a non-alert outbox event transitions to DEAD_LETTER. Prevents recursive alert generation and preserves the original correlation ID.';

revoke all
on function public.enqueue_outbox_dead_letter_alert_v1()
from public;

revoke all
on function public.enqueue_outbox_dead_letter_alert_v1()
from anon;

revoke all
on function public.enqueue_outbox_dead_letter_alert_v1()
from authenticated;