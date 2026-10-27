import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { ApiError } from '../core/api-error';
import { httpErrorInterceptor } from '../core/http-error.interceptor';
import { RequestItem, RequestSummary } from './request.models';
import { RequestsApiService, readConflictDetails, toHttpParams } from './requests-api.service';

const item: RequestItem = {
  id: 7,
  title: 'Renew permit',
  organizationName: 'Acme',
  status: 'New',
  priority: 'High',
  assignedTo: null,
  createdAt: '2026-10-01T08:00:00Z',
  updatedAt: '2026-10-01T08:00:00Z',
  rowVersion: 'AAAAAAAAB9E=',
  allowedNextStatuses: ['InProgress', 'Waiting'],
};

describe('RequestsApiService', () => {
  let api: RequestsApiService;
  let controller: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    api = TestBed.inject(RequestsApiService);
    controller = TestBed.inject(HttpTestingController);
  });

  afterEach(() => controller.verify());

  it('GET /api/requests sends the search params and returns the page', () => {
    const page = { items: [item], page: 2, pageSize: 10, totalCount: 11, totalPages: 2 };
    let result: unknown;
    api
      .search({
        page: 2,
        pageSize: 10,
        status: ['New', 'Waiting'],
        sortBy: 'title',
        sortDirection: 'asc',
      })
      .subscribe((r) => (result = r));

    const req = controller.expectOne((r) => r.url === '/api/requests');
    expect(req.request.method).toBe('GET');
    expect(req.request.params.getAll('status')).toEqual(['New', 'Waiting']);
    expect(req.request.params.get('page')).toBe('2');
    expect(req.request.params.get('sortBy')).toBe('title');
    req.flush(page);
    expect(result).toEqual(page);
  });

  it('GET /api/requests/summary', () => {
    const summary: RequestSummary = {
      total: 1,
      byStatus: [{ status: 'New', count: 1 }],
      byPriority: [{ priority: 'High', count: 1 }],
      generatedAt: '2026-10-25T10:00:00Z',
    };
    let result: unknown;
    api.getSummary().subscribe((r) => (result = r));

    const req = controller.expectOne('/api/requests/summary');
    expect(req.request.method).toBe('GET');
    req.flush(summary);
    expect(result).toEqual(summary);
  });

  it('GET /api/requests/{id}', () => {
    let result: unknown;
    api.getById(7).subscribe((r) => (result = r));

    const req = controller.expectOne('/api/requests/7');
    expect(req.request.method).toBe('GET');
    req.flush(item);
    expect(result).toEqual(item);
  });

  it('GET /api/requests/{id}/history', () => {
    const history = [
      {
        id: 2,
        requestId: 7,
        previousStatus: 'InProgress',
        newStatus: 'Completed',
        changedAt: '2026-10-02T09:00:00Z',
        changedBy: 'dana',
      },
    ];
    let result: unknown;
    api.getHistory(7).subscribe((r) => (result = r));

    const req = controller.expectOne('/api/requests/7/history');
    expect(req.request.method).toBe('GET');
    req.flush(history);
    expect(result).toEqual(history);
  });

  it('PATCH /api/requests/{id}/status sends status, rowVersion and X-User-Name', () => {
    let result: unknown;
    api
      .updateStatus(
        7,
        { status: 'InProgress', rowVersion: item.rowVersion },
        { changedBy: ' dana ' },
      )
      .subscribe((r) => (result = r));

    const req = controller.expectOne('/api/requests/7/status');
    expect(req.request.method).toBe('PATCH');
    expect(req.request.body).toEqual({ status: 'InProgress', rowVersion: item.rowVersion });
    expect(req.request.headers.get('X-User-Name')).toBe('dana');
    req.flush({ ...item, status: 'InProgress' });
    expect((result as RequestItem).status).toBe('InProgress');
  });

  it.each([['Dana Levi‏ דנה'], ['דנה'], ['José'], ['a'.repeat(101)], ['line\nbreak'], ['   ']])(
    'PATCH does not send an X-User-Name the header cannot carry (%j)',
    (name) => {
      api
        .updateStatus(7, { status: 'Waiting', rowVersion: item.rowVersion }, { changedBy: name })
        .subscribe();

      const req = controller.expectOne('/api/requests/7/status');
      expect(req.request.headers.has('X-User-Name')).toBe(false);
      req.flush(item);
    },
  );

  it('PATCH sends a 100-character ASCII X-User-Name', () => {
    api
      .updateStatus(
        7,
        { status: 'Waiting', rowVersion: item.rowVersion },
        { changedBy: 'a'.repeat(100) },
      )
      .subscribe();

    const req = controller.expectOne('/api/requests/7/status');
    expect(req.request.headers.get('X-User-Name')).toBe('a'.repeat(100));
    req.flush(item);
  });

  it('PATCH omits X-User-Name when no name is given', () => {
    api.updateStatus(7, { status: 'Waiting', rowVersion: item.rowVersion }).subscribe();

    const req = controller.expectOne('/api/requests/7/status');
    expect(req.request.headers.has('X-User-Name')).toBe(false);
    req.flush(item);
  });

  it('POST /api/requests/bulk-status sends the envelope and returns per-item results', () => {
    const response = {
      requested: 2,
      succeeded: 1,
      failed: 1,
      results: [
        { id: 1, outcome: 'Updated', rowVersion: 'AAAAAAAAB9E=', error: null },
        {
          id: 2,
          outcome: 'Conflict',
          rowVersion: 'AAAAAAAAB9I=',
          error: 'The request was changed by someone else.',
        },
      ],
    };
    let result: unknown;
    api
      .bulkUpdateStatus('Completed', [
        { id: 1, rowVersion: 'AAAAAAAAB9A=' },
        { id: 2, rowVersion: 'AAAAAAAAB9B=' },
      ])
      .subscribe((r) => (result = r));

    const req = controller.expectOne('/api/requests/bulk-status');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual({
      status: 'Completed',
      items: [
        { id: 1, rowVersion: 'AAAAAAAAB9A=' },
        { id: 2, rowVersion: 'AAAAAAAAB9B=' },
      ],
    });
    req.flush(response);
    expect(result).toEqual(response);
  });

  it('surfaces a 409 as an ApiError with typed conflict details', () => {
    let caught: unknown;
    api
      .updateStatus(7, { status: 'InProgress', rowVersion: 'stale' })
      .subscribe({ error: (e: unknown) => (caught = e) });

    controller.expectOne('/api/requests/7/status').flush(
      {
        title: 'Concurrency conflict.',
        status: 409,
        currentStatus: 'Waiting',
        currentRowVersion: 'AAAAAAAAB9M=',
      },
      { status: 409, statusText: 'Conflict' },
    );

    expect(caught).toBeInstanceOf(ApiError);
    expect(readConflictDetails(caught as ApiError)).toEqual({
      currentStatus: 'Waiting',
      currentRowVersion: 'AAAAAAAAB9M=',
    });
  });
});

describe('toHttpParams', () => {
  it('repeats status and priority once per value', () => {
    const params = toHttpParams({ status: ['New', 'Waiting'], priority: ['Low', 'High'] });
    expect(params.toString()).toBe('status=New&status=Waiting&priority=Low&priority=High');
  });

  it('skips undefined, empty and blank values but keeps zero-length arrays out', () => {
    const params = toHttpParams({
      search: '   ',
      organizationName: '',
      assignedTo: undefined,
      status: [],
      priority: [],
    });
    expect(params.keys()).toEqual([]);
  });

  it('sends dates as ISO 8601 UTC', () => {
    const params = toHttpParams({
      createdFrom: new Date('2026-01-01T00:00:00Z'),
      createdTo: new Date('2026-02-01T00:00:00Z'),
    });
    expect(params.get('createdFrom')).toBe('2026-01-01T00:00:00.000Z');
    expect(params.get('createdTo')).toBe('2026-02-01T00:00:00.000Z');
  });

  it('maps every scalar parameter by its API name', () => {
    const params = toHttpParams({
      page: 3,
      pageSize: 50,
      search: 'permit',
      organizationName: 'Ac',
      assignedTo: 'dana',
      sortBy: 'updatedAt',
      sortDirection: 'desc',
    });
    expect(params.toString()).toBe(
      'page=3&pageSize=50&search=permit&organizationName=Ac&assignedTo=dana&sortBy=updatedAt&sortDirection=desc',
    );
  });
});

describe('readConflictDetails', () => {
  it('returns null for a non-409 error', () => {
    expect(readConflictDetails(ApiError.fromResponse(422, { title: 'Not allowed.' }))).toBeNull();
  });

  it('returns null when the 409 lacks the conflict members', () => {
    expect(readConflictDetails(ApiError.fromResponse(409, { title: 'Conflict.' }))).toBeNull();
    expect(
      readConflictDetails(
        ApiError.fromResponse(409, { currentStatus: 'Bogus', currentRowVersion: 'AA==' }),
      ),
    ).toBeNull();
  });
});
