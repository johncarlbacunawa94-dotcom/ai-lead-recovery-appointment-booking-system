# n8n Workflows

Phase 4 workflow: `p4-retell-lifecycle-outbox-worker.json`.
See [P4 setup and validation](P4-RETELL-LIFECYCLE.md) for import instructions and failure behavior.

n8n is used only for asynchronous orchestration,
scheduled work, retries, notifications, reporting, event handling,
missed-call recovery, and dormant-reactivation workflows.

Real-time Retell booking/tool calls must not depend directly on n8n.
