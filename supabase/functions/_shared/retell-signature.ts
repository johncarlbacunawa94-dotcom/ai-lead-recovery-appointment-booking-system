const RETELL_SIGNATURE_MAX_AGE_MS = 5 * 60 * 1000;

export type RetellSignatureVerification = {
  valid: boolean;
  reason:
    | "VALID"
    | "MISSING_SIGNATURE"
    | "MALFORMED_SIGNATURE"
    | "INVALID_TIMESTAMP"
    | "STALE_TIMESTAMP"
    | "INVALID_DIGEST";
};

function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
    return null;
  }

  const bytes = new Uint8Array(hex.length / 2);

  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = Number.parseInt(hex.slice(i, i + 2), 16);
  }

  return bytes;
}

function timingSafeEqual(
  left: Uint8Array,
  right: Uint8Array,
): boolean {
  if (left.length !== right.length) {
    return false;
  }

  let diff = 0;

  for (let i = 0; i < left.length; i += 1) {
    diff |= left[i] ^ right[i];
  }

  return diff === 0;
}

export async function verifyRetellSignature(
  rawBody: string,
  apiKey: string,
  signature: string | null,
  nowMs = Date.now(),
): Promise<RetellSignatureVerification> {
  if (!signature) {
    return {
      valid: false,
      reason: "MISSING_SIGNATURE",
    };
  }

  const match = /^v=(\d+),d=([0-9a-fA-F]{64})$/.exec(
    signature.trim(),
  );

  if (!match) {
    return {
      valid: false,
      reason: "MALFORMED_SIGNATURE",
    };
  }

  const timestampText = match[1];
  const suppliedDigestHex = match[2];

  const timestamp = Number(timestampText);

  if (!Number.isSafeInteger(timestamp)) {
    return {
      valid: false,
      reason: "INVALID_TIMESTAMP",
    };
  }

  if (
    Math.abs(nowMs - timestamp) >
      RETELL_SIGNATURE_MAX_AGE_MS
  ) {
    return {
      valid: false,
      reason: "STALE_TIMESTAMP",
    };
  }

  const encoder = new TextEncoder();

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(apiKey),
    {
      name: "HMAC",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );

  const expectedDigestBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(rawBody + timestampText),
  );

  const expectedDigest = new Uint8Array(
    expectedDigestBuffer,
  );

  const suppliedDigest = hexToBytes(
    suppliedDigestHex,
  );

  if (
    suppliedDigest === null ||
    !timingSafeEqual(
      expectedDigest,
      suppliedDigest,
    )
  ) {
    return {
      valid: false,
      reason: "INVALID_DIGEST",
    };
  }

  return {
    valid: true,
    reason: "VALID",
  };
}