import type {
  RetellToolName,
} from "./retell-envelope.ts";


export type ToolArgumentValidationResult =
  | {
      ok: true;
    }
  | {
      ok: false;
      issues: string[];
    };


const LOCATION_CODES = new Set([
  "BRISBANE",
  "MELBOURNE",
  "SYDNEY",
  "PERTH",
  "OTHER",
  "UNKNOWN",
]);


const STATED_INTENTS = new Set([
  "PROFESSIONAL_TRAINING",
  "BUSINESS_PARTNERSHIP",
  "GENERAL_SERVICE",
  "UNKNOWN",
]);


const HANDOFF_REASONS = new Set([
  "EXPLICIT_HUMAN_REQUEST",
  "SENSITIVE_OR_CLINICAL",
  "LOW_CONFIDENCE",
  "UNSUPPORTED_KNOWLEDGE",
  "HIGH_VALUE_OPPORTUNITY",
  "CALLER_FRUSTRATION",
  "BOOKING_FAILURE",
  "TOOL_FAILURE",
  "CONFLICTING_INTENT",
  "OUT_OF_SCOPE",
]);


function isRecord(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}


function isNullableString(
  value: unknown,
  maxLength: number,
): boolean {
  return (
    value === null ||
    (
      typeof value === "string" &&
      value.length <= maxLength
    )
  );
}


function isNonEmptyString(
  value: unknown,
  maxLength: number,
): value is string {
  return (
    typeof value === "string" &&
    value.trim().length > 0 &&
    value.length <= maxLength
  );
}


function isValidEmailAddress(
  value: unknown,
): value is string {
  if (
    !isNonEmptyString(
      value,
      320,
    )
  ) {
    return false;
  }


  const candidate =
    value
      .normalize("NFKC")
      .trim()
      .toLocaleLowerCase(
        "en-AU",
      );


  if (
    candidate.length === 0 ||
    /\s/.test(candidate)
  ) {
    return false;
  }


  const parts =
    candidate.split("@");


  if (
    parts.length !== 2
  ) {
    return false;
  }


  const [
    localPart,
    domainPart,
  ] = parts;


  return (
    localPart.length > 0 &&
    domainPart.length > 0 &&
    domainPart.includes(".") &&
    !domainPart.startsWith(".") &&
    !domainPart.endsWith(".")
  );
}


function isDateTimeWithZone(
  value: unknown,
): value is string {
  if (typeof value !== "string") {
    return false;
  }

  // Require an explicit timezone so local/server timezone
  // can never silently change appointment interpretation.
  const zonePattern =
    /(Z|[+-]\d{2}:\d{2})$/;

  if (!zonePattern.test(value)) {
    return false;
  }

  return !Number.isNaN(
    Date.parse(value),
  );
}


function isValidIanaTimezone(
  value: unknown,
): value is string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.length > 100
  ) {
    return false;
  }

  try {
    new Intl.DateTimeFormat(
      "en-US",
      {
        timeZone: value,
      },
    ).format();

    return true;
  } catch {
    return false;
  }
}


function unexpectedKeys(
  args: Record<string, unknown>,
  allowed: readonly string[],
): string[] {
  const allowedSet =
    new Set(allowed);

  return Object.keys(args)
    .filter(
      (key) =>
        !allowedSet.has(key),
    )
    .map(
      (key) =>
        `unexpected property: ${key}`,
    );
}


function missingKeys(
  args: Record<string, unknown>,
  required: readonly string[],
): string[] {
  return required
    .filter(
      (key) =>
        !Object.prototype.hasOwnProperty.call(
          args,
          key,
        ),
    )
    .map(
      (key) =>
        `missing required property: ${key}`,
    );
}


function validateCaptureProspectContext(
  args: Record<string, unknown>,
): string[] {
  const allowed = [
    "first_name",
    "last_name",
    "company_name",
    "phone",
    "email",
    "location_code",
    "stated_intent",
    "initial_enquiry_summary",
  ] as const;

  const issues = unexpectedKeys(
    args,
    allowed,
  );

  if (Object.keys(args).length === 0) {
    issues.push(
      "at least one property is required",
    );
  }

  if (
    "first_name" in args &&
    !isNullableString(
      args.first_name,
      100,
    )
  ) {
    issues.push(
      "first_name is invalid",
    );
  }

  if (
    "last_name" in args &&
    !isNullableString(
      args.last_name,
      100,
    )
  ) {
    issues.push(
      "last_name is invalid",
    );
  }

  if (
    "company_name" in args &&
    !isNullableString(
      args.company_name,
      200,
    )
  ) {
    issues.push(
      "company_name is invalid",
    );
  }

  if (
    "phone" in args &&
    !isNullableString(
      args.phone,
      50,
    )
  ) {
    issues.push(
      "phone is invalid",
    );
  }

  if (
    "email" in args &&
    !isNullableString(
      args.email,
      320,
    )
  ) {
    issues.push(
      "email is invalid",
    );
  }

  if (
    "location_code" in args &&
    args.location_code !== null &&
    (
      typeof args.location_code !==
        "string" ||
      !LOCATION_CODES.has(
        args.location_code,
      )
    )
  ) {
    issues.push(
      "location_code is invalid",
    );
  }

  if (
    "stated_intent" in args &&
    args.stated_intent !== null &&
    (
      typeof args.stated_intent !==
        "string" ||
      !STATED_INTENTS.has(
        args.stated_intent,
      )
    )
  ) {
    issues.push(
      "stated_intent is invalid",
    );
  }

  if (
    "initial_enquiry_summary" in args &&
    !isNullableString(
      args.initial_enquiry_summary,
      1000,
    )
  ) {
    issues.push(
      "initial_enquiry_summary is invalid",
    );
  }

  return issues;
}


function validateCorrectPrimaryEmail(
  args: Record<string, unknown>,
): string[] {
  const allowed = [
    "corrected_email",
  ] as const;

  const required = [
    "corrected_email",
  ] as const;

  const issues = [
    ...unexpectedKeys(
      args,
      allowed,
    ),
    ...missingKeys(
      args,
      required,
    ),
  ];


  if (
    "corrected_email" in args &&
    !isValidEmailAddress(
      args.corrected_email,
    )
  ) {
    issues.push(
      "corrected_email is invalid",
    );
  }


  return issues;
}


function validateAvailability(
  args: Record<string, unknown>,
): string[] {
  const allowed = [
    "requested_timezone",
    "window_start",
    "window_end",
  ] as const;

  const required = [
    "requested_timezone",
    "window_start",
    "window_end",
  ] as const;

  const issues = [
    ...unexpectedKeys(
      args,
      allowed,
    ),
    ...missingKeys(
      args,
      required,
    ),
  ];

  if (
    "requested_timezone" in args &&
    !isValidIanaTimezone(
      args.requested_timezone,
    )
  ) {
    issues.push(
      "requested_timezone is invalid",
    );
  }

  if (
    "window_start" in args &&
    !isDateTimeWithZone(
      args.window_start,
    )
  ) {
    issues.push(
      "window_start is invalid",
    );
  }

  if (
    "window_end" in args &&
    !isDateTimeWithZone(
      args.window_end,
    )
  ) {
    issues.push(
      "window_end is invalid",
    );
  }

  if (
    isDateTimeWithZone(
      args.window_start,
    ) &&
    isDateTimeWithZone(
      args.window_end,
    )
  ) {
    const start =
      Date.parse(args.window_start);

    const end =
      Date.parse(args.window_end);

    if (start >= end) {
      issues.push(
        "window_start must precede window_end",
      );
    }
  if (end <= Date.now()) {
    issues.push(
      "availability window must not be entirely in the past",
    );
  }
  }

  return issues;
}


function validateCreateAppointment(
  args: Record<string, unknown>,
): string[] {
  const allowed = [
    "booking_request_id",
    "slot_token",
  ] as const;

  const required = [
    "booking_request_id",
    "slot_token",
  ] as const;

  const issues = [
    ...unexpectedKeys(
      args,
      allowed,
    ),
    ...missingKeys(
      args,
      required,
    ),
  ];

  if (
    "booking_request_id" in args &&
    !isNonEmptyString(
      args.booking_request_id,
      500,
    )
  ) {
    issues.push(
      "booking_request_id is invalid",
    );
  }

  if (
    "slot_token" in args &&
    !isNonEmptyString(
      args.slot_token,
      2000,
    )
  ) {
    issues.push(
      "slot_token is invalid",
    );
  }

  return issues;
}


function validateHumanHandoff(
  args: Record<string, unknown>,
): string[] {
  const allowed = [
    "reason_code",
    "caller_requested",
    "brief_context",
  ] as const;

  const required = [
    "reason_code",
    "caller_requested",
  ] as const;

  const issues = [
    ...unexpectedKeys(
      args,
      allowed,
    ),
    ...missingKeys(
      args,
      required,
    ),
  ];

  if (
    "reason_code" in args &&
    (
      typeof args.reason_code !==
        "string" ||
      !HANDOFF_REASONS.has(
        args.reason_code,
      )
    )
  ) {
    issues.push(
      "reason_code is invalid",
    );
  }

  if (
    "caller_requested" in args &&
    typeof args.caller_requested !==
      "boolean"
  ) {
    issues.push(
      "caller_requested is invalid",
    );
  }

  if (
    "brief_context" in args &&
    !isNullableString(
      args.brief_context,
      1000,
    )
  ) {
    issues.push(
      "brief_context is invalid",
    );
  }

  return issues;
}


export function validateRetellToolArgs(
  toolName: RetellToolName,
  args: unknown,
): ToolArgumentValidationResult {
  if (!isRecord(args)) {
    return {
      ok: false,
      issues: [
        "args must be an object",
      ],
    };
  }

  let issues: string[];

  switch (toolName) {
    case
      "capture_prospect_context_v1":

      issues =
        validateCaptureProspectContext(
          args,
        );

      break;


    case
      "correct_primary_email_v1":

      issues =
        validateCorrectPrimaryEmail(
          args,
        );

      break;


    case
      "check_appointment_availability_v1":

      issues =
        validateAvailability(
          args,
        );

      break;


    case
      "create_appointment_v1":

      issues =
        validateCreateAppointment(
          args,
        );

      break;


    case
      "request_human_handoff_v1":

      issues =
        validateHumanHandoff(
          args,
        );

      break;
  }

  if (issues.length > 0) {
    return {
      ok: false,
      issues,
    };
  }

  return {
    ok: true,
  };
}
