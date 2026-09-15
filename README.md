# AI Lead Recovery & Appointment Booking System

Portfolio implementation for the fictional demo business:

**Meridian Professional Training & Services**

This repository demonstrates a production-shaped lead recovery,
voice-AI, appointment booking, human escalation, and SMS recovery
architecture with deterministic business-state controls.

## Current status

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | Architecture and foundation design | LOCKED |
| Phase 2 / 3 | Core infrastructure, Retell tools, context capture, booking | VERIFIED |
| Phase 4 | Post-call analysis and business-state processing | COMPLETE / FROZEN |
| Phase 5 | Human handoff, notifications, dead-letter operations | COMPLETE / FROZEN |
| Phase 6A | Twilio provider boundary and webhook ingress | COMPLETE |
| Phase 6B | Deterministic missed-call recovery | COMPLETE |
| Phase 6C | Safe recovery SMS orchestration | COMPLETE / FROZEN |
| Phase 6D | Inbound SMS reply and opt-out handling | COMPLETE / FROZEN |
| Phase 6E | Live Twilio carrier / Australian PSTN verification | DEFERRED |

## Core architecture

- **Retell AI** — real-time voice conversation and approved tool invocation
- **Supabase PostgreSQL** — authoritative business state
- **Supabase Edge Functions** — synchronous provider and tool boundaries
- **Cal.com** — appointment availability and booking provider
- **self-hosted n8n** — asynchronous orchestration only
- **Twilio** — SMS / telephony provider boundary
- **Gmail SMTP** — operator notifications

PostgreSQL remains the source of truth.

AI and n8n do not authoritatively control critical business state.

## Implemented capabilities

- signed Retell provider ingress
- canonical call resolution
- deterministic tool validation
- idempotent prospect-context capture
- appointment availability and booking
- structured post-call analysis
- deterministic business-state application
- human-handoff queueing
- operator notification
- dead-letter alerting
- Twilio webhook signature verification
- Twilio-shaped provider event ingestion
- deterministic missed-call recovery
- pre-send SMS eligibility / DND / consent enforcement
- durable outbound SMS-attempt state
- safe retry / unknown-outcome handling
- inbound SMS persistence
- replay-safe inbound processing
- STOP / opt-out enforcement
- ambiguous-phone review handling
- scheduled n8n recovery workers

## Twilio verification boundary

The Twilio integration and provider contracts are implemented and have
been exercised using controlled test-mode provider data.

The project does **not** claim that the following have been verified:

- production Twilio account authentication
- Australian Twilio number provisioning
- real SMS carrier delivery
- real PSTN calling
- live inbound carrier webhook delivery
- real telephone transfer

Those items remain Phase 6E.

## Architectural rules

- fictional/demo data only
- no real customer or patient information
- no medical advice
- internal IDs are never model-controlled
- DND and contact eligibility are deterministic
- AI cannot reverse deterministic opt-out state
- synchronous Retell tools do not depend on n8n
- provider events are persisted before asynchronous processing
- PostgreSQL owns authoritative lifecycle and business-state transitions
- secrets are not committed to Git

## Repository structure

- `supabase/` — database migrations and Edge Functions
- `n8n/` — exported asynchronous workers
- `docs/architecture/` — locked architecture and current-state snapshots
- `docs/contracts/` — tool and AI-output contracts
- `tests/` — implementation validation
- `scripts/` — supporting development / verification utilities

See `docs/architecture/` for the authoritative architecture documents.