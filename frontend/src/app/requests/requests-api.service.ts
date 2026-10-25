import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { ApiError } from '../core/api-error';
import {
  BulkStatusItem,
  BulkStatusUpdateBody,
  BulkStatusUpdateResult,
  ConflictDetails,
  PagedResult,
  REQUEST_STATUSES,
  RequestItem,
  RequestSearchParams,
  RequestStatus,
  RequestSummary,
  StatusHistoryEntry,
  UpdateStatusBody,
} from './request.models';

const BASE_URL = '/api/requests';
const CHANGED_BY_HEADER = 'X-User-Name';

/** Optional `X-User-Name` value stored by the API as `changedBy` (at most 100 characters, not authenticated). */
export interface ChangedByOptions {
  readonly changedBy?: string;
}

/**
 * The only place that talks to the requests API. Failed calls reach subscribers as `ApiError`
 * (see `httpErrorInterceptor`); components never inject `HttpClient`.
 */
@Injectable({ providedIn: 'root' })
export class RequestsApiService {
  private readonly http = inject(HttpClient);

  /** `GET /api/requests`: server-side search, filter, sort and paging. */
  search(params: RequestSearchParams = {}): Observable<PagedResult<RequestItem>> {
    return this.http.get<PagedResult<RequestItem>>(BASE_URL, { params: toHttpParams(params) });
  }

  /** `GET /api/requests/summary`: global counts by status and priority. */
  getSummary(): Observable<RequestSummary> {
    return this.http.get<RequestSummary>(`${BASE_URL}/summary`);
  }

  /** `GET /api/requests/{id}`. */
  getById(id: number): Observable<RequestItem> {
    return this.http.get<RequestItem>(`${BASE_URL}/${id}`);
  }

  /** `GET /api/requests/{id}/history`: newest first, empty when the request never changed. */
  getHistory(id: number): Observable<readonly StatusHistoryEntry[]> {
    return this.http.get<readonly StatusHistoryEntry[]>(`${BASE_URL}/${id}/history`);
  }

  /** `PATCH /api/requests/{id}/status`. Fails with a 409 `ApiError` when `rowVersion` is stale. */
  updateStatus(id: number, body: UpdateStatusBody, options: ChangedByOptions = {}): Observable<RequestItem> {
    return this.http.patch<RequestItem>(`${BASE_URL}/${id}/status`, body, { headers: toHeaders(options) });
  }

  /** `POST /api/requests/bulk-status`: partial success, one result per item in the order sent. */
  bulkUpdateStatus(
    status: RequestStatus,
    items: readonly BulkStatusItem[],
    options: ChangedByOptions = {},
  ): Observable<BulkStatusUpdateResult> {
    const body: BulkStatusUpdateBody = { status, items };
    return this.http.post<BulkStatusUpdateResult>(`${BASE_URL}/bulk-status`, body, {
      headers: toHeaders(options),
    });
  }
}

/** Builds the query string. Repeats `status` / `priority` per value; skips unset and blank values. */
export function toHttpParams(params: RequestSearchParams): HttpParams {
  let result = new HttpParams();
  const set = (name: string, value: string | number | undefined): void => {
    if (value === undefined || (typeof value === 'string' && value.trim() === '')) {
      return;
    }
    result = result.set(name, value);
  };

  set('page', params.page);
  set('pageSize', params.pageSize);
  set('search', params.search);
  for (const status of params.status ?? []) {
    result = result.append('status', status);
  }
  for (const priority of params.priority ?? []) {
    result = result.append('priority', priority);
  }
  set('organizationName', params.organizationName);
  set('assignedTo', params.assignedTo);
  set('createdFrom', params.createdFrom?.toISOString());
  set('createdTo', params.createdTo?.toISOString());
  set('sortBy', params.sortBy);
  set('sortDirection', params.sortDirection);
  return result;
}

/** Reads the typed members of a 409 `ApiError`, or `null` when the error is not a well-formed conflict. */
export function readConflictDetails(error: ApiError): ConflictDetails | null {
  if (error.status !== 409) {
    return null;
  }
  const { currentStatus, currentRowVersion } = error.extensions;
  if (
    typeof currentRowVersion === 'string' &&
    typeof currentStatus === 'string' &&
    (REQUEST_STATUSES as readonly string[]).includes(currentStatus)
  ) {
    return { currentStatus: currentStatus as RequestStatus, currentRowVersion };
  }
  return null;
}

/** Same limit as `ChangedBy.MaxLength` in the backend. */
const CHANGED_BY_MAX_LENGTH = 100;

/** Printable ASCII only: browsers reject other characters in a header value, and the API cannot read them back. */
const HEADER_SAFE = /^[\x20-\x7E]+$/;

/**
 * `X-User-Name` is optional, and the API stores `anonymous` when it is missing. A name the header cannot carry
 * (non-ASCII, or over 100 characters, which the API answers with 400) is therefore not sent at all.
 */
function toHeaders(options: ChangedByOptions): HttpHeaders {
  const changedBy = options.changedBy?.trim();
  return changedBy && changedBy.length <= CHANGED_BY_MAX_LENGTH && HEADER_SAFE.test(changedBy)
    ? new HttpHeaders({ [CHANGED_BY_HEADER]: changedBy })
    : new HttpHeaders();
}
