/** Parsed `application/problem+json` body (RFC 9457), as produced by the API. */
interface ProblemDetailsBody {
  title?: unknown;
  detail?: unknown;
  traceId?: unknown;
  errors?: unknown;
}

const NETWORK_ERROR_TITLE = 'The server could not be reached.';

/** The single error shape the UI works with. `status` is 0 when no response was received. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly title: string,
    readonly detail: string | null = null,
    readonly traceId: string | null = null,
    /** Validation messages keyed by field (400 responses). */
    readonly errors: Readonly<Record<string, readonly string[]>> = {},
    /** Remaining ProblemDetails members, e.g. `currentStatus` and `currentRowVersion` on a 409. */
    readonly extensions: Readonly<Record<string, unknown>> = {},
  ) {
    super(detail ?? title);
    this.name = 'ApiError';
  }

  static fromResponse(status: number, body: unknown): ApiError {
    if (status === 0) {
      return new ApiError(0, NETWORK_ERROR_TITLE);
    }
    if (typeof body !== 'object' || body === null) {
      return new ApiError(status, `Request failed (${status}).`);
    }
    const { title, detail, traceId, errors, ...rest } = body as ProblemDetailsBody & Record<string, unknown>;
    const extensions = Object.fromEntries(
      Object.entries(rest).filter(([key]) => !['type', 'status', 'instance'].includes(key)),
    );
    return new ApiError(
      status,
      typeof title === 'string' ? title : `Request failed (${status}).`,
      typeof detail === 'string' ? detail : null,
      typeof traceId === 'string' ? traceId : null,
      toFieldErrors(errors),
      extensions,
    );
  }
}

function toFieldErrors(errors: unknown): Record<string, readonly string[]> {
  if (typeof errors !== 'object' || errors === null) {
    return {};
  }
  const result: Record<string, readonly string[]> = {};
  for (const [field, messages] of Object.entries(errors)) {
    if (Array.isArray(messages)) {
      result[field] = messages.filter((m): m is string => typeof m === 'string');
    }
  }
  return result;
}
