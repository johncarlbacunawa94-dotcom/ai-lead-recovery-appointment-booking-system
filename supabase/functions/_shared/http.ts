export type ErrorBody = {
  error: {
    code: string;
    message: string;
    correlation_id: string;
  };
};

const COMMON_HEADERS: HeadersInit = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

export function jsonResponse(
  body: unknown,
  status = 200,
): Response {
  return new Response(
    JSON.stringify(body),
    {
      status,
      headers: COMMON_HEADERS,
    },
  );
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
  correlationId: string,
): Response {
  const body: ErrorBody = {
    error: {
      code,
      message,
      correlation_id: correlationId,
    },
  };

  return jsonResponse(body, status);
}