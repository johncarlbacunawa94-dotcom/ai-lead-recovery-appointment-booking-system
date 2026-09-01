export type ToolRuntimeContext = {
  correlationId: string;

  provider: "RETELL";

  providerCallId: string;

  providerCallType:
    | "web_call"
    | "phone_call";

  canonicalCallId: string;

  canonicalCallCorrelationId: string;

  prospectId:
    | string
    | null;

  opportunityId:
    | string
    | null;

  agentId:
    | string
    | null;

  agentVersion:
    | number
    | null;

  direction:
    | "inbound"
    | "outbound"
    | null;
};