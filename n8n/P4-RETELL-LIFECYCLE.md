# P4 — Retell Lifecycle Outbox Worker

Import `p4-retell-lifecycle-outbox-worker.json` using n8n's **Import from File** menu. It contains the complete five-node workflow. The file omits a workflow ID so importing does not overwrite an existing workflow by ID. The existing three-node P4 draft remains unchanged; use the imported complete version for the eventual manual test.

The workflow is inactive and has only a Manual Trigger. Do not publish, activate, or add a schedule yet. Importing does not execute the RPCs. Confirm all three HTTP Request nodes show the existing **Supabase account** credential before a future manual execution. Its ID/name are preserved; no credential secret is included.

## Behavior

Manual Trigger → Worker Context → Claim Lifecycle Event → Reconcile Call Lifecycle → Complete Outbox Event

- Worker ID: `p4-retell-lifecycle-` plus the n8n execution ID.
- Claim filters: `RETELL_CALL_STARTED`, `RETELL_CALL_ENDED`, `RETELL_CALL_ANALYZED`; limit 1; lock timeout 30 seconds.
- Reconcile receives the claimed row's `source_raw_provider_event_id` as `p_raw_provider_event_id`.
- Complete receives the original claim's `outbox_event_id` and the same worker ID, independently of the reconciliation response.
- HTTP Request 4.4 expands JSON response arrays into items. An empty claim array emits zero items, ending the run without reconciliation or completion. Always Output Data is disabled.
- HTTP failures stop execution. Continue On Fail, automatic retries, redirects, and Never Error are disabled. Completion only follows a successful reconciliation response.
- Each RPC request has an 8-second timeout; the workflow timeout is 25 seconds. These reduce lease overrun risk but cannot cancel a server-side transaction or guarantee timing under load. Backend lock ownership remains authoritative.
- The intentionally minimal initial path does not call `fail_outbox_event_v1`. Failed/uncertain runs leave the lease for the existing stale-lock recovery on a later manual claim after 30 seconds; backend attempt limits and dead-letter handling still apply. An HTTP timeout does not prove the RPC rolled back. Do not manually mark uncertain events complete.
- Execution payload persistence is disabled for manual, successful, and failed runs. No pinned data is included.

## Validation completed

Inspected local n8n **2.29.7**, its installed node implementations, the existing inactive P4 workflow, and the deployed RPC definitions in the repository (read-only).

Validated all node parameters with the installed n8n node schemas and constructed an n8n `Workflow` instance. Offline expression checks verified worker identity, exact claim parameters, source raw-event mapping, and completion identity after reconciliation replaces the current item. Checked connections, inactive state, credential references, error settings, timeouts, and absence of embedded secrets/pinned data. Inspected the installed HTTP node's empty-array and error behavior.

No live RPC execution or live import was performed. Runtime credential access, service-role authorization, connectivity, and actual event processing remain to be verified by a future manual run. That run claims and mutates one eligible real outbox event; it is not a dry run.

No backend, migrations, Edge Functions, Retell configuration, Cal.com, booking logic, or post-call AI analysis was changed.
