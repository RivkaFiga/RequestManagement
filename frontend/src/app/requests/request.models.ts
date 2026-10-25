/**
 * Wire types of the requests API (plan §4.2). They mirror the backend DTOs in `RequestManagement.Core`:
 * enums travel as strings, dates as ISO 8601 UTC strings, `rowVersion` as an opaque base64 string.
 */

export const REQUEST_STATUSES = ['New', 'InProgress', 'Waiting', 'Completed'] as const;
export type RequestStatus = (typeof REQUEST_STATUSES)[number];

/** Ordered Low → High, like the backend enum. */
export const REQUEST_PRIORITIES = ['Low', 'Medium', 'High'] as const;
export type RequestPriority = (typeof REQUEST_PRIORITIES)[number];

export const REQUEST_SORT_FIELDS = ['createdAt', 'updatedAt', 'priority', 'status', 'title'] as const;
export type RequestSortField = (typeof REQUEST_SORT_FIELDS)[number];

export type SortDirection = 'asc' | 'desc';

/** Per-item outcome of the bulk endpoint (also the outcomes of a single update). */
export type StatusUpdateOutcome = 'Updated' | 'NotFound' | 'Conflict' | 'InvalidTransition';

/** `RequestDto`. */
export interface RequestItem {
  readonly id: number;
  readonly title: string;
  readonly organizationName: string;
  readonly status: RequestStatus;
  readonly priority: RequestPriority;
  readonly assignedTo: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly rowVersion: string;
  readonly allowedNextStatuses: readonly RequestStatus[];
}

/** `PagedResult<T>`. */
export interface PagedResult<T> {
  readonly items: readonly T[];
  readonly page: number;
  readonly pageSize: number;
  readonly totalCount: number;
  readonly totalPages: number;
}

/** `StatusHistoryEntryDto`. */
export interface StatusHistoryEntry {
  readonly id: number;
  readonly requestId: number;
  readonly previousStatus: RequestStatus;
  readonly newStatus: RequestStatus;
  readonly changedAt: string;
  readonly changedBy: string;
}

/** `StatusCountDto`. */
export interface StatusCount {
  readonly status: RequestStatus;
  readonly count: number;
}

/** `PriorityCountDto`. */
export interface PriorityCount {
  readonly priority: RequestPriority;
  readonly count: number;
}

/** `RequestSummaryDto`: global counts that ignore the list filters. */
export interface RequestSummary {
  readonly total: number;
  readonly byStatus: readonly StatusCount[];
  readonly byPriority: readonly PriorityCount[];
  readonly generatedAt: string;
}

/** Body of `PATCH /api/requests/{id}/status`. */
export interface UpdateStatusBody {
  readonly status: RequestStatus;
  /** The `rowVersion` of the last response for this request. */
  readonly rowVersion: string;
}

/** One entry of `BulkStatusUpdateBody.items`. */
export interface BulkStatusItem {
  readonly id: number;
  readonly rowVersion: string;
}

/** Body of `POST /api/requests/bulk-status` (1–100 items, distinct ids). */
export interface BulkStatusUpdateBody {
  readonly status: RequestStatus;
  readonly items: readonly BulkStatusItem[];
}

/** `BulkStatusItemResultDto`. `rowVersion` is the new one after `Updated`, the current one after `Conflict`. */
export interface BulkStatusItemResult {
  readonly id: number;
  readonly outcome: StatusUpdateOutcome;
  readonly rowVersion: string | null;
  readonly error: string | null;
}

/** `BulkStatusUpdateResultDto`. */
export interface BulkStatusUpdateResult {
  readonly requested: number;
  readonly succeeded: number;
  readonly failed: number;
  readonly results: readonly BulkStatusItemResult[];
}

/** Filters, sorting and paging of `GET /api/requests`. Omitted or blank values are not sent. */
export interface RequestSearchParams {
  readonly page?: number;
  readonly pageSize?: number;
  readonly search?: string;
  readonly status?: readonly RequestStatus[];
  readonly priority?: readonly RequestPriority[];
  readonly organizationName?: string;
  readonly assignedTo?: string;
  /** Inclusive lower bound on `createdAt`. */
  readonly createdFrom?: Date;
  /** Exclusive upper bound on `createdAt`. */
  readonly createdTo?: Date;
  readonly sortBy?: RequestSortField;
  readonly sortDirection?: SortDirection;
}

/** The extra members of a 409 response (`ApiError.extensions`): what the request looks like now. */
export interface ConflictDetails {
  readonly currentStatus: RequestStatus;
  readonly currentRowVersion: string;
}
