# n8n Workflows

n8n is used only for asynchronous orchestration.

It does not own authoritative business-state transitions.

Authoritative state remains in PostgreSQL and is mutated through
controlled database contracts / RPCs.

## Exported workflows

### Phase 4

`p4-retell-lifecycle-outbox-worker.json`

Supports asynchronous Retell lifecycle / outbox processing.

See:

`P4-RETELL-LIFECYCLE.md`

### Phase 5

`p5-human-handoff-notification-worker.json`

Processes:

`HUMAN_HANDOFF_REQUESTED`

Responsibilities include:

- claim authoritative outbox work
- load handoff evidence
- build operator notification
- send SMTP notification
- complete or fail the outbox event

### Phase 5D

`p5d-dead-letter-operator-alert-worker.json`

Processes:

`OUTBOX_DEAD_LETTER_ALERT`

The database owns dead-letter creation and recursion prevention.

n8n owns asynchronous operator notification delivery.

### Phase 6C

`p6c-missed-call-recovery-sms-worker.json`

Processes:

`TWILIO_MISSED_CALL_RECOVERY_READY`

Flow:

claim recovery work
-> invoke the protected recovery-SMS Edge Function
-> route deterministic result
-> complete or fail the outbox event

The worker does not independently decide whether SMS may be sent.

PostgreSQL and the Edge Function re-check authoritative eligibility,
DND, consent, idempotency, and durable send-attempt state.

Required runtime environment variables:

- `P6C_SUPABASE_SERVICE_ROLE_KEY`
- `P6C_RECOVERY_WORKER_SECRET`

### Phase 6D

`p6d-twilio-inbound-sms-worker.json`

Processes:

`TWILIO_INCOMING_MESSAGE`

Flow:

claim inbound-message work
-> reconcile authoritative inbound SMS state
-> route result
-> complete or fail the source outbox event

Inbound reconciliation is idempotent by provider message identity.

STOP / opt-out behavior is applied authoritatively in PostgreSQL,
not in n8n.

Required runtime environment variable:

- `P6C_SUPABASE_SERVICE_ROLE_KEY`

## Runtime notes

The current self-hosted Windows n8n runtime uses native Node `https`
from Code nodes because the HTTP Request node exhibited backend-network
timeouts in the tested environment.

The n8n process is launched with:

- `NODE_FUNCTION_ALLOW_BUILTIN=https,http`
- `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`

The second setting permits Code nodes to read process environment
variables and therefore increases the trust placed in locally installed
workflows.

Secrets are stored outside the repository and are not embedded in
workflow exports.

## Scheduling

Published asynchronous workers use scheduled polling.

The Phase 6C and Phase 6D workers were verified with successful
empty-queue scheduled executions.

Real-time Retell booking and tool calls must not depend directly on n8n.