import { HttpError } from "./environment";

const encoder = new TextEncoder();

export async function readJSON(
  request: Request,
  maximumBytes = 32 * 1024,
): Promise<Record<string, unknown>> {
  const contentLength = request.headers.get("Content-Length");
  const declared = contentLength === null ? undefined : Number(contentLength);
  if (declared !== undefined && (!Number.isSafeInteger(declared) || declared < 0)) {
    throw new HttpError(400, "invalidRequest", "Content-Length is invalid");
  }
  if (declared !== undefined && declared > maximumBytes) {
    throw new HttpError(413, "requestTooLarge", "Request body is too large");
  }
  const reader = request.body?.getReader();
  if (!reader) {
    throw new HttpError(400, "invalidRequest", "Request body is empty");
  }
  const chunks: Uint8Array[] = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maximumBytes) {
      await reader.cancel();
      throw new HttpError(413, "requestTooLarge", "Request body is too large");
    }
    chunks.push(value);
  }
  if (received === 0) {
    throw new HttpError(400, "invalidRequest", "Request body is empty");
  }
  const data = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    data.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(data));
  } catch {
    throw new HttpError(400, "invalidJSON", "Request body is not valid JSON");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new HttpError(400, "invalidRequest", "Request body must be a JSON object");
  }
  return value as Record<string, unknown>;
}

export function bearerToken(request: Request): string {
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    throw new HttpError(401, "unauthorized", "Bearer authorization is required");
  }
  const token = authorization.slice(7);
  if (token.length === 0 || encoder.encode(token).byteLength > 4096
    || /[\u0000-\u0020\u007f]/u.test(token)) {
    throw new HttpError(401, "unauthorized", "Bearer authorization is invalid");
  }
  return token;
}

export function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export function assertExactKeys(value: Record<string, unknown>, keys: string[]): void {
  const expected = new Set(keys);
  if (Object.keys(value).some((key) => !expected.has(key))) {
    throw new HttpError(400, "invalidRequest", "Request contains an unknown field");
  }
}
