import twilio from "npm:twilio@6.1.1";


export type TwilioSmsTemplateCode =
  "MISSED_CALL_RECOVERY_V1";


export type TwilioSmsTransportMode =
  | "MOCK"
  | "LIVE";


export type TwilioSmsMockScenario =
  | "SUCCESS"
  | "REJECTED_400"
  | "REJECTED_429"
  | "UNKNOWN_NETWORK";


export type TwilioSmsTransportConfig = {
  mode: TwilioSmsTransportMode;

  accountSid: string;
  authToken: string;

  fromPhone: string;

  statusCallbackUrl:
    | string
    | null;

  mockScenario?:
    TwilioSmsMockScenario;
};


export type TwilioSmsTransportInput = {
  toPhone: string;

  templateCode:
    TwilioSmsTemplateCode;
};


export type TwilioSmsAcceptedResult = {
  outcome: "ACCEPTED";

  provider: "TWILIO";

  providerMessageId: string;
  providerStatus: string;

  retryable: false;
};


export type TwilioSmsRejectedResult = {
  outcome: "REJECTED";

  provider: "TWILIO";

  retryable: boolean;

  errorCode:
    | string
    | null;

  sanitizedMessage: string;
};


export type TwilioSmsUnknownResult = {
  outcome: "UNKNOWN";

  provider: "TWILIO";

  retryable: false;

  errorCode:
    | string
    | null;

  sanitizedMessage: string;
};


export type TwilioSmsTransportResult =
  | TwilioSmsAcceptedResult
  | TwilioSmsRejectedResult
  | TwilioSmsUnknownResult;


type MockRequestOptions = {
  method?: unknown;
  uri?: unknown;
  data?: unknown;
};


type MockExpectedRequest = {
  accountSid: string;

  toPhone: string;
  fromPhone: string;

  body: string;

  statusCallbackUrl:
    | string
    | null;
};


const E164_PATTERN =
  /^\+[1-9][0-9]{7,14}$/;


const ACCOUNT_SID_PATTERN =
  /^AC[0-9a-fA-F]{32}$/;


const MESSAGE_SID_PATTERN =
  /^SM[0-9a-fA-F]{32}$/;


function requireNonEmpty(
  value: string,
  fieldName: string,
): string {

  const normalized =
    value.trim();


  if (normalized.length === 0) {
    throw new Error(
      `${fieldName} is required`,
    );
  }


  return normalized;
}


function requireE164(
  value: string,
  fieldName: string,
): string {

  const normalized =
    requireNonEmpty(
      value,
      fieldName,
    );


  if (
    !E164_PATTERN.test(
      normalized,
    )
  ) {
    throw new Error(
      `${fieldName} must be canonical E.164`,
    );
  }


  return normalized;
}


function validateStatusCallbackUrl(
  value:
    | string
    | null,
): string | null {

  if (value === null) {
    return null;
  }


  const normalized =
    value.trim();


  if (normalized.length === 0) {
    return null;
  }


  let parsed: URL;


  try {
    parsed =
      new URL(
        normalized,
      );

  } catch {
    throw new Error(
      "statusCallbackUrl must be a valid URL",
    );
  }


  if (
    parsed.protocol !== "https:"
  ) {
    throw new Error(
      "statusCallbackUrl must use HTTPS",
    );
  }


  return parsed.toString();
}


export function renderTwilioSmsTemplate(
  templateCode:
    TwilioSmsTemplateCode,
): string {

  switch (templateCode) {

    case "MISSED_CALL_RECOVERY_V1":
      return (
        "Sorry we missed your call. " +
        "Reply here and we'll get back to you as soon as we can. " +
        "Reply STOP to opt out."
      );

    default: {
      const exhaustive:
        never =
        templateCode;

      throw new Error(
        `unsupported SMS template: ${String(exhaustive)}`,
      );
    }
  }
}


function makeMockMessageSid(): string {

  return (
    "SM" +
    crypto
      .randomUUID()
      .replaceAll(
        "-",
        "",
      )
  );
}


function asDataRecord(
  value: unknown,
): Record<string, unknown> {

  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value)
  ) {
    throw new Error(
      "Twilio SDK request data was not an object",
    );
  }


  return value as
    Record<string, unknown>;
}


class MockTwilioRequestClient {

  constructor(
    private readonly scenario:
      TwilioSmsMockScenario,

    private readonly expected:
      MockExpectedRequest,
  ) {}


  async request(
    options:
      MockRequestOptions,
  ): Promise<{
    statusCode: number;
    body: unknown;
  }> {

    const method =
      String(
        options.method ?? "",
      )
        .toUpperCase();


    if (method !== "POST") {
      throw new Error(
        `mock expected POST, received ${method}`,
      );
    }


    const uri =
      String(
        options.uri ?? "",
      );


    const expectedPath =
      (
        `/2010-04-01/Accounts/` +
        `${this.expected.accountSid}/` +
        `Messages.json`
      );


    if (
      !uri.includes(
        expectedPath,
      )
    ) {
      throw new Error(
        "Twilio SDK used an unexpected Messages API URI",
      );
    }


    const data =
      asDataRecord(
        options.data,
      );


    if (
      data.To !==
      this.expected.toPhone
    ) {
      throw new Error(
        "Twilio SDK request contained an unexpected To value",
      );
    }


    if (
      data.From !==
      this.expected.fromPhone
    ) {
      throw new Error(
        "Twilio SDK request contained an unexpected From value",
      );
    }


    if (
      data.Body !==
      this.expected.body
    ) {
      throw new Error(
        "Twilio SDK request contained an unexpected Body value",
      );
    }


    if (
      this.expected
        .statusCallbackUrl !== null
    ) {
      if (
        data.StatusCallback !==
        this.expected
          .statusCallbackUrl
      ) {
        throw new Error(
          "Twilio SDK request contained an unexpected StatusCallback",
        );
      }

    } else if (
      data.StatusCallback !== undefined
    ) {
      throw new Error(
        "Twilio SDK unexpectedly supplied StatusCallback",
      );
    }


    switch (
      this.scenario
    ) {

      case "SUCCESS":
        return {
          statusCode: 201,

          body: {
            sid:
              makeMockMessageSid(),

            account_sid:
              this.expected
                .accountSid,

            to:
              this.expected
                .toPhone,

            from:
              this.expected
                .fromPhone,

            body:
              this.expected
                .body,

            status:
              "queued",
          },
        };


      case "REJECTED_400":
        return {
          statusCode: 400,

          body: {
            status: 400,
            code: 21211,

            message:
              "Mock Twilio request rejected.",

            more_info:
              "https://www.twilio.com/docs/errors/21211",
          },
        };


      case "REJECTED_429":
        return {
          statusCode: 429,

          body: {
            status: 429,
            code: 20429,

            message:
              "Mock Twilio rate limit rejection.",

            more_info:
              "https://www.twilio.com/docs/errors/20429",
          },
        };


      case "UNKNOWN_NETWORK":
        throw new Error(
          "MOCK_NETWORK_OUTCOME_UNKNOWN",
        );
    }
  }
}


function numericErrorStatus(
  error: unknown,
): number | null {

  if (
    error === null ||
    typeof error !== "object"
  ) {
    return null;
  }


  const candidate =
    Number(
      (
        error as
          Record<string, unknown>
      ).status,
    );


  if (
    !Number.isInteger(candidate)
  ) {
    return null;
  }


  return candidate;
}


function providerErrorCode(
  error: unknown,
): string | null {

  if (
    error === null ||
    typeof error !== "object"
  ) {
    return null;
  }


  const candidate =
    (
      error as
        Record<string, unknown>
    ).code;


  if (
    candidate === undefined ||
    candidate === null
  ) {
    return null;
  }


  return String(candidate);
}


function classifyTransportError(
  error: unknown,
): TwilioSmsTransportResult {

  const status =
    numericErrorStatus(
      error,
    );

  const errorCode =
    providerErrorCode(
      error,
    );


  if (
    status !== null &&
    status >= 400 &&
    status < 500
  ) {
    return {
      outcome:
        "REJECTED",

      provider:
        "TWILIO",

      retryable:
        status === 429,

      errorCode,

      sanitizedMessage:
        status === 429
          ? "Twilio rejected the SMS request because of rate limiting."
          : "Twilio rejected the SMS request.",
    };
  }


  return {
    outcome:
      "UNKNOWN",

    provider:
      "TWILIO",

    retryable:
      false,

    errorCode,

    sanitizedMessage:
      (
        "The Twilio SMS request outcome is unknown. " +
        "Automatic resend is unsafe."
      ),
  };
}


export async function sendTwilioRecoverySms(
  config:
    TwilioSmsTransportConfig,

  input:
    TwilioSmsTransportInput,
): Promise<
  TwilioSmsTransportResult
> {

  const accountSid =
    requireNonEmpty(
      config.accountSid,
      "accountSid",
    );


  if (
    !ACCOUNT_SID_PATTERN.test(
      accountSid,
    )
  ) {
    throw new Error(
      "accountSid is not a valid Twilio Account SID",
    );
  }


  const authToken =
    requireNonEmpty(
      config.authToken,
      "authToken",
    );


  const fromPhone =
    requireE164(
      config.fromPhone,
      "fromPhone",
    );


  const toPhone =
    requireE164(
      input.toPhone,
      "toPhone",
    );


  const statusCallbackUrl =
    validateStatusCallbackUrl(
      config.statusCallbackUrl,
    );


  const body =
    renderTwilioSmsTemplate(
      input.templateCode,
    );


  const createOptions:
    Record<string, string> = {
      to:
        toPhone,

      from:
        fromPhone,

      body,
    };


  if (
    statusCallbackUrl !== null
  ) {
    createOptions.statusCallback =
      statusCallbackUrl;
  }


  let requestClient:
    unknown;


  if (
    config.mode === "MOCK"
  ) {
    requestClient =
      new MockTwilioRequestClient(
        config.mockScenario ??
          "SUCCESS",

        {
          accountSid,

          toPhone,
          fromPhone,

          body,

          statusCallbackUrl,
        },
      );
  }


  const client =
    twilio(
      accountSid,
      authToken,

      config.mode === "MOCK"
        ? {
            httpClient:
              requestClient as any,
          }
        : undefined,
    );


  try {
    const message =
      await client.messages.create(
        createOptions,
      );


    const providerMessageId =
      String(
        message.sid ?? "",
      );


    if (
      !MESSAGE_SID_PATTERN.test(
        providerMessageId,
      )
    ) {
      throw new Error(
        "Twilio returned an invalid Message SID",
      );
    }


    return {
      outcome:
        "ACCEPTED",

      provider:
        "TWILIO",

      providerMessageId,

      providerStatus:
        String(
          message.status ??
            "unknown",
        ),

      retryable:
        false,
    };

  } catch (error) {

    return classifyTransportError(
      error,
    );
  }
}