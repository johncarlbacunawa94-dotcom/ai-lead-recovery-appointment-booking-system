# Application and AI Contracts

These files are the authoritative Phase 2A contracts.

## Files

- `tool-contracts.v1.json`
  - Canonical real-time Voice AI tool contracts.
  - Separates Retell provider transport context from agent-controlled arguments.

- `ai-output-contracts.v1.json`
  - Structured AI inference schemas.

## Authority boundaries

Retell sends provider transport context separately from function arguments.

The application service must verify the Retell signature before trusting:

- provider call ID;
- call type;
- agent identity/version;
- provider request context.

The LLM must never invent:

- canonical call IDs;
- prospect IDs;
- opportunity IDs;
- correlation IDs;
- authoritative lifecycle state;
- contact eligibility;
- DND state;
- booking truth.

## Tool rules

1. AI inference is separate from authoritative business state.
2. Critical lifecycle transitions remain deterministic.
3. DND and contact eligibility are never model-controlled.
4. Booking success comes only from backend/provider truth.
5. Side-effecting tools require idempotency.
6. Availability slot tokens are opaque controlled references.
7. Booking request IDs are controlled references, not invented identifiers.
8. Unsupported and sensitive cases have an explicit human path.
9. A human handoff may exist against a call before prospect/opportunity resolution.
10. Retell provider retries must not be enabled until the endpoint is proven idempotent.
11. Schema changes require explicit contract versioning after v1 is committed.
12. Retell configuration must conform to these contracts rather than becoming an independent source of truth.