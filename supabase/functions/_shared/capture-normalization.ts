import {
  parsePhoneNumberFromString,
} from "npm:libphonenumber-js@1.13.12/min";


export type NormalizedCaptureArguments = {
  firstName: string | null;
  lastName: string | null;
  companyName: string | null;

  emailRaw: string | null;
  emailNormalized: string | null;

  phoneRaw: string | null;
  phoneNormalized: string | null;

  locationCode: string | null;
  statedIntent: string | null;

  hashArguments: {
    first_name: string | null;
    last_name: string | null;
    company_name: string | null;
    phone: string | null;
    email: string | null;
    location_code: string | null;
    stated_intent: string | null;
  };
};


function normalizedText(
  value: unknown,
): string | null {
  if (
    typeof value !== "string"
  ) {
    return null;
  }

  const normalized =
    value
      .normalize("NFKC")
      .replace(/\s+/g, " ")
      .trim();

  return (
    normalized.length > 0
      ? normalized
      : null
  );
}


function identityHashText(
  value: string | null,
): string | null {
  return (
    value === null
      ? null
      : value.toLocaleLowerCase(
          "en-AU",
        )
  );
}


function normalizeEmail(
  value: string | null,
): string | null {
  if (!value) {
    return null;
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
    candidate.length > 320 ||
    /\s/.test(candidate)
  ) {
    return null;
  }


  const parts =
    candidate.split("@");


  if (
    parts.length !== 2
  ) {
    return null;
  }


  const [
    localPart,
    domainPart,
  ] = parts;


  if (
    localPart.length === 0 ||
    domainPart.length === 0 ||
    !domainPart.includes(".")
  ) {
    return null;
  }


  if (
    domainPart.startsWith(".") ||
    domainPart.endsWith(".")
  ) {
    return null;
  }


  return candidate;
}


function normalizePhone(
  value: string | null,
): string | null {
  if (!value) {
    return null;
  }


  try {
    const parsed =
      parsePhoneNumberFromString(
        value,
        "AU",
      );


    if (
      !parsed ||
      !parsed.isValid()
    ) {
      return null;
    }


    return parsed.number;

  } catch {
    return null;
  }
}


export function normalizeCaptureArguments(
  args: Record<string, unknown>,
): NormalizedCaptureArguments {

  const firstName =
    normalizedText(
      args.first_name,
    );

  const lastName =
    normalizedText(
      args.last_name,
    );

  const companyName =
    normalizedText(
      args.company_name,
    );

  const emailRaw =
    normalizedText(
      args.email,
    );

  const phoneRaw =
    normalizedText(
      args.phone,
    );

  const emailNormalized =
    normalizeEmail(
      emailRaw,
    );

  const phoneNormalized =
    normalizePhone(
      phoneRaw,
    );

  const locationCode =
    normalizedText(
      args.location_code,
    );

  const statedIntent =
    normalizedText(
      args.stated_intent,
    );


  return {
    firstName,
    lastName,
    companyName,

    emailRaw,
    emailNormalized,

    phoneRaw,
    phoneNormalized,

    locationCode,
    statedIntent,

    hashArguments: {
      first_name:
        identityHashText(
          firstName,
        ),

      last_name:
        identityHashText(
          lastName,
        ),

      company_name:
        identityHashText(
          companyName,
        ),

      phone:
        phoneNormalized,

      email:
        emailNormalized,

      location_code:
        locationCode,

      stated_intent:
        statedIntent,
    },
  };
}