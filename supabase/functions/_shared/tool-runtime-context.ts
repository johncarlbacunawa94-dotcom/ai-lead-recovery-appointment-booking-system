export type ToolRuntimeContext = {
  correlationId: string;

  provider: "RETELL";

  providerCallId: string;

  providerCallType:
    | "web_call"
    | "phone_call";

  agentId: string | null;

  agentVersion: number | null;

  direction:
    | "inbound"
    | "outbound"
    | null;
};