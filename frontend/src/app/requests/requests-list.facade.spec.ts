import { provideHttpClient, withInterceptors } from '@angular/common/http';
import {
  HttpTestingController,
  TestRequest,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '../core/api-error';
import { httpErrorInterceptor } from '../core/http-error.interceptor';
import { PagedResult, RequestItem } from './request.models';
import { RequestsListFacade, SEARCH_DEBOUNCE_MS } from './requests-list.facade';

const item: RequestItem = {
  id: 1,
  title: 'Renew permit',
  organizationName: 'Acme',
  status: 'New',
  priority: 'High',
  assignedTo: null,
  createdAt: '2026-10-01T08:00:00Z',
  updatedAt: '2026-10-01T08:00:00Z',
  rowVersion: 'AAAAAAAAB9E=',
  allowedNextStatuses: ['InProgress'],
};

function page(items: readonly RequestItem[]): PagedResult<RequestItem> {
  return {
    items,
    page: 1,
    pageSize: 20,
    totalCount: items.length,
    totalPages: items.length === 0 ? 0 : 1,
  };
}

describe('RequestsListFacade', () => {
  let facade: RequestsListFacade;
  let http: HttpTestingController;

  const pending = (): TestRequest[] => http.match((r) => r.url === '/api/requests');

  beforeEach(() => {
    vi.useFakeTimers();
    TestBed.configureTestingModule({
      providers: [
        RequestsListFacade,
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    facade = TestBed.inject(RequestsListFacade);
    // The initial load.
    http.expectOne((r) => r.url === '/api/requests').flush(page([]));
  });

  afterEach(() => {
    http.verify();
    vi.useRealTimers();
  });

  it('sends one request per typing pause, with the final text', () => {
    facade.setSearch('p');
    vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS - 1);
    facade.setSearch('pe');
    vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS - 1);
    facade.setSearch('per');

    expect(pending()).toHaveLength(0);

    vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS);
    const calls = pending();
    expect(calls).toHaveLength(1);
    expect(calls[0].request.params.get('search')).toBe('per');
    expect(calls[0].request.params.get('page')).toBe('1');
    calls[0].flush(page([item]));
  });

  it('cancels the request in flight when a newer query arrives', () => {
    facade.setFilters({ status: ['New'] });
    const first = http.expectOne((r) => r.url === '/api/requests');

    facade.setFilters({ status: ['Waiting'] });
    const second = http.expectOne((r) => r.url === '/api/requests');

    expect(first.cancelled).toBe(true);
    expect(second.cancelled).toBe(false);

    second.flush(page([item]));
    expect(facade.state().status).toBe('loaded');
    expect(facade.items()).toEqual([item]);
  });

  it('a filter change creates a new request and resets to page 1', () => {
    facade.setPage(3);
    http.expectOne((r) => r.url === '/api/requests').flush({ ...page([item]), page: 3 });
    expect(facade.query().page).toBe(3);

    facade.setFilters({ status: ['New', 'Waiting'], priority: ['High'] });
    const req = http.expectOne((r) => r.url === '/api/requests');

    expect(req.request.params.get('page')).toBe('1');
    expect(req.request.params.getAll('status')).toEqual(['New', 'Waiting']);
    expect(req.request.params.getAll('priority')).toEqual(['High']);
    req.flush(page([item]));
  });

  it('sort and page changes send their parameters', () => {
    facade.setSort('title', 'asc');
    const sorted = http.expectOne((r) => r.url === '/api/requests');
    expect(sorted.request.params.get('sortBy')).toBe('title');
    expect(sorted.request.params.get('sortDirection')).toBe('asc');
    sorted.flush(page([item]));

    facade.setPage(2);
    const paged = http.expectOne((r) => r.url === '/api/requests');
    expect(paged.request.params.get('page')).toBe('2');
    expect(paged.request.params.get('sortBy')).toBe('title');
    paged.flush(page([item]));
  });

  it('goes loading → loaded with items', () => {
    facade.refresh();
    expect(facade.state().status).toBe('loading');
    expect(facade.loading()).toBe(true);

    http.expectOne((r) => r.url === '/api/requests').flush(page([item]));

    expect(facade.state().status).toBe('loaded');
    expect(facade.loading()).toBe(false);
    expect(facade.empty()).toBe(false);
    expect(facade.error()).toBeNull();
  });

  it('goes loading → loaded and reports empty when there are no items', () => {
    facade.refresh();
    expect(facade.loading()).toBe(true);

    http.expectOne((r) => r.url === '/api/requests').flush(page([]));

    expect(facade.state().status).toBe('loaded');
    expect(facade.empty()).toBe(true);
  });

  it('goes loading → error with an ApiError, and refresh retries', () => {
    facade.refresh();
    expect(facade.loading()).toBe(true);

    http
      .expectOne((r) => r.url === '/api/requests')
      .flush({ title: 'Server error' }, { status: 500, statusText: 'Server Error' });

    expect(facade.state().status).toBe('error');
    expect(facade.error()).toBeInstanceOf(ApiError);
    expect(facade.error()?.status).toBe(500);
    expect(facade.items()).toEqual([]);

    facade.refresh();
    expect(facade.state().status).toBe('loading');
    expect(facade.error()).toBeNull();
    http.expectOne((r) => r.url === '/api/requests').flush(page([item]));
    expect(facade.state().status).toBe('loaded');
  });
});
