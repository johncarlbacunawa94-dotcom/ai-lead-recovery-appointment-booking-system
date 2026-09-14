import twilio from "npm:twilio@6.1.1";


export type TwilioFormParams =
  Record<
    string,
    string | string[]
  >;


export type TwilioSignatureVerification = {
  valid: boolean;

  reason:
    | "VALID"
    | "MISSING_SIGNATURE"
    | "INVALID_SIGNATURE"
    | "VERIFICATION_ERROR";
};


export function verifyTwilioFormSignature(
  authToken: string,
  signature: string | null,
  webhookUrl: string,
  params: TwilioFormParams,
): TwilioSignatureVerification {

  if (!signature) {
    return {
      valid: false,
      reason:
        "MISSING_SIGNATURE",
    };
  }


  try {
    const valid =
      twilio.validateRequest(
        authToken,
        signature,
        webhookUrl,
        params,
      );


    return valid
      ? {
          valid: true,
          reason: "VALID",
        }
      : {
          valid: false,
          reason:
            "INVALID_SIGNATURE",
        };
  } catch {
    return {
      valid: false,
      reason:
        "VERIFICATION_ERROR",
    };
  }
}