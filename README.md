# AI Lead Recovery & Appointment Booking System

Professional portfolio demonstration for:

**Meridian Professional Training & Services — Demo**

This project demonstrates:

- Voice AI
- persistent prospect and opportunity state
- knowledge-grounded conversations
- appointment availability and booking
- human escalation
- missed-call recovery
- dormant-lead reactivation
- deterministic eligibility controls
- idempotency
- auditability
- failure handling
- CRM-agnostic architecture

## Status

Phase 1 — Architecture & Foundation Design: LOCKED

Phase 2A — Infrastructure Foundation: IN PROGRESS

## Core architecture

- Retell AI — real-time conversational voice layer
- Supabase / PostgreSQL — authoritative system of record
- Supabase Edge Functions / application services — synchronous business logic
- Cal.com API v2 — booking provider
- self-hosted n8n — asynchronous orchestration
- Twilio — later telephony and SMS transport
- Next.js / React — later operator interface if justified

## Important rules

- Fictional/demo data only
- No real customer or patient information
- No medical advice
- AI does not control critical business state
- DND and contact eligibility are deterministic
- Real-time critical tools do not route through n8n
- Provider events are persisted before asynchronous processing
- No secrets are committed to Git

See:

`docs/architecture/`

for the authoritative architecture specification.
