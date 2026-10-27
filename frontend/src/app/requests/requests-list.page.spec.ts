import { provideHttpClient, withInterceptors } from '@angular/common/http';
import {
  HttpTestingController,
  TestRequest,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { TestbedHarnessEnvironment } from '@angular/cdk/testing/testbed';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { MatSelectHarness } from '@angular/material/select/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { httpErrorInterceptor } from '../core/http-error.interceptor';
import { PagedResult, RequestItem } from './request.models';
import { SEARCH_DEBOUNCE_MS } from './requests-list.facade';
import { RequestsListPage, toLabel } from './requests-list.page';

const item: RequestItem = {
  id: 1,
  title: 'Renew permit',
  organizationName: 'Acme',
  status: 'InProgress',
  priority: 'High',
  assignedTo: null,
  createdAt: '2026-10-01T08:00:00Z',
  updatedAt: '2026-10-01T08:00:00Z',
  rowVersion: 'AAAAAAAAB9E=',
  allowedNextStatuses: ['Waiting'],
};

function page(
  items: readonly RequestItem[],
  pageNumber = 1,
  totalCount = items.length,
): PagedResult<RequestItem> {
  return {
    items,
    page: pageNumber,
    pageSize: 20,
    totalCount,
    totalPages: Math.ceil(totalCount / 20),
  };
}

describe('RequestsListPage', () => {
  let fixture: ComponentFixture<RequestsListPage>;
  let http: HttpTestingController;
  let element: HTMLElement;

  const lastRequest = (): TestRequest => {
    const pending = http.match((r) => r.url === '/api/requests');
    expect(pending).toHaveLength(1);
    return pending[0];
  };
  const settle = async (): Promise<void> => {
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  };
  const click = async (selector: string): Promise<void> => {
    (element.querySelector(selector) as HTMLElement).click();
    await settle();
  };

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [RequestsListPage],
      providers: [
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(RequestsListPage);
    element = fixture.nativeElement as HTMLElement;
    await settle();
    http
      .expectOne('/api/requests/summary')
      .flush({ total: 0, byStatus: [], byPriority: [], generatedAt: '2026-10-25T08:00:00Z' });
  });

  afterEach(() => {
    http.verify();
    vi.useRealTimers();
  });

  it('shows the loading indicator, then the rows of the page', async () => {
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();
    expect(element.querySelector('table')).toBeNull();

    lastRequest().flush(page([item], 1, 41));
    await settle();

    expect(element.querySelector('mat-progress-bar')).toBeNull();
    const cells = Array.from(element.querySelectorAll('tbody tr:first-child td')).map((c) =>
      c.textContent?.trim(),
    );
    expect(cells.slice(0, 5)).toEqual(['Renew permit', 'Acme', 'In progress', 'High', '—']);
    expect(element.querySelector('.mat-mdc-paginator-range-label')?.textContent).toContain('of 41');
  });

  it('opens the history dialog of a row and loads its history', async () => {
    lastRequest().flush(page([item]));
    await settle();

    await click('[data-testid="history-button"]');
    http.expectOne('/api/requests/1/history').flush([]);
    await settle();

    const dialog = document.querySelector('app-request-history-dialog');
    expect(dialog?.textContent).toContain('#1 · Renew permit');
    expect(dialog?.querySelector('[data-testid="history-empty"]')).toBeTruthy();
  });

  it('shows the empty state', async () => {
    lastRequest().flush(page([]));
    await settle();

    expect(element.querySelector('[role="status"]')?.textContent).toContain('No requests match');
    expect(element.querySelector('table')).toBeNull();
  });

  it('shows the error and retries the same query', async () => {
    lastRequest().flush(
      { title: 'Boom', detail: 'Database unavailable' },
      { status: 500, statusText: 'Server Error' },
    );
    await settle();

    const alert = element.querySelector('[role="alert"]');
    expect(alert?.textContent).toContain('Database unavailable');

    await click('[role="alert"] button');
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();
    const retry = lastRequest();
    expect(retry.request.params.get('page')).toBe('1');
    retry.flush(page([item]));
    await settle();

    expect(element.querySelector('[role="alert"]')).toBeNull();
    expect(element.querySelectorAll('tbody tr')).toHaveLength(1);
  });

  it('sends the sort to the server', async () => {
    lastRequest().flush(page([item]));
    await settle();

    await click('th.mat-column-title .mat-sort-header-container');
    const request = lastRequest();
    expect(request.request.params.get('sortBy')).toBe('title');
    expect(request.request.params.get('sortDirection')).toBe('asc');
    request.flush(page([item]));
  });

  it('requests the next page from the server', async () => {
    lastRequest().flush(page([item], 1, 41));
    await settle();

    await click('button.mat-mdc-paginator-navigation-next');
    const request = lastRequest();
    expect(request.request.params.get('page')).toBe('2');
    expect(request.request.params.get('pageSize')).toBe('20');
    request.flush(page([item], 2, 41));
  });

  it('sends the applied filters from the first page', async () => {
    lastRequest().flush(page([item], 1, 41));
    await settle();

    const page2 = element.querySelector('button.mat-mdc-paginator-navigation-next') as HTMLElement;
    page2.click();
    await settle();
    lastRequest().flush(page([item], 2, 41));
    await settle();

    const set = (name: string, value: string): void => {
      const input = element.querySelector(`input[formcontrolname="${name}"]`) as HTMLInputElement;
      input.value = value;
      input.dispatchEvent(new Event('input'));
    };
    set('organizationName', 'Ac');
    set('assignedTo', 'dana');
    set('createdFrom', '2026-10-01');
    set('createdTo', '2026-10-05');
    await settle();
    await click('button[type="submit"]');

    const { params } = lastRequest().request;
    expect(params.get('page')).toBe('1');
    expect(params.get('organizationName')).toBe('Ac');
    expect(params.get('assignedTo')).toBe('dana');
    expect(new Date(params.get('createdFrom') as string).getTime()).toBe(
      new Date('2026-10-01T00:00:00').getTime(),
    );
    expect(new Date(params.get('createdTo') as string).getTime()).toBe(
      new Date('2026-10-06T00:00:00').getTime(),
    );
    // The summary is global (A4): applying filters does not reload it.
    expect(http.match((r) => r.url === '/api/requests/summary')).toHaveLength(0);
  });

  it('does not apply a date range whose end is before its start', async () => {
    lastRequest().flush(page([item]));
    await settle();

    const set = (name: string, value: string): void => {
      const input = element.querySelector(`input[formcontrolname="${name}"]`) as HTMLInputElement;
      input.value = value;
      input.dispatchEvent(new Event('input'));
    };
    set('createdFrom', '2026-10-05');
    set('createdTo', '2026-10-01');
    await settle();

    expect((element.querySelector('button[type="submit"]') as HTMLButtonElement).disabled).toBe(
      true,
    );
  });

  it('searches after the typing pause, and never sends a single character', async () => {
    lastRequest().flush(page([item]));
    await settle();
    vi.useFakeTimers();

    const input = element.querySelector('input[type="search"]') as HTMLInputElement;
    const type = (value: string): void => {
      input.value = value;
      input.dispatchEvent(new Event('input'));
    };
    type('p');
    vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS);
    expect(http.match((r) => r.url === '/api/requests')).toHaveLength(0);

    type('pe');
    vi.advanceTimersByTime(SEARCH_DEBOUNCE_MS);
    const request = lastRequest();
    expect(request.request.params.get('search')).toBe('pe');
    expect(request.request.params.get('page')).toBe('1');
    request.flush(page([item]));
  });
});

describe('RequestsListPage status change', () => {
  const STATUS_URL = '/api/requests/1/status';
  const updated: RequestItem = {
    ...item,
    status: 'Waiting',
    rowVersion: 'AAAAAAAAB9F=',
    allowedNextStatuses: ['InProgress', 'Completed'],
  };

  let fixture: ComponentFixture<RequestsListPage>;
  let http: HttpTestingController;
  let element: HTMLElement;

  const settle = async (): Promise<void> => {
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  };
  const flushList = async (items: readonly RequestItem[]): Promise<void> => {
    const pending = http.match((r) => r.url === '/api/requests');
    expect(pending).toHaveLength(1);
    pending[0].flush(page(items));
    await settle();
  };
  const flushSummary = async (): Promise<void> => {
    http
      .expectOne('/api/requests/summary')
      .flush({ total: 1, byStatus: [], byPriority: [], generatedAt: '2026-10-25T08:00:00Z' });
    await settle();
  };
  const updateButton = (): HTMLButtonElement =>
    element.querySelector('app-status-change button') as HTMLButtonElement;
  /** Picks a status in the row's select and presses Update. */
  const changeTo = async (label: string): Promise<void> => {
    const select = await TestbedHarnessEnvironment.loader(fixture).getHarness(
      MatSelectHarness.with({ ancestor: 'app-status-change' }),
    );
    await select.clickOptions({ text: label });
    updateButton().click();
    await settle();
  };
  const notice = (): HTMLElement | null => element.querySelector('[data-testid="status-notice"]');

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [RequestsListPage],
      providers: [
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(RequestsListPage);
    element = fixture.nativeElement as HTMLElement;
    await settle();
    await flushSummary();
    await flushList([item]);
  });

  afterEach(() => http.verify());

  it('limits the choice to the allowed next statuses and needs a choice before Update', async () => {
    expect(updateButton().disabled).toBe(true);

    const select = await TestbedHarnessEnvironment.loader(fixture).getHarness(
      MatSelectHarness.with({ ancestor: 'app-status-change' }),
    );
    await select.open();
    const options = await select.getOptions();
    expect(await Promise.all(options.map((o) => o.getText()))).toEqual(['Waiting']);
  });

  it('sends status and rowVersion, shows saving, then the success and the reloaded list and summary', async () => {
    await changeTo('Waiting');

    const patch = http.expectOne(STATUS_URL);
    expect(patch.request.method).toBe('PATCH');
    expect(patch.request.body).toEqual({ status: 'Waiting', rowVersion: item.rowVersion });
    expect(patch.request.headers.has('X-User-Name')).toBe(false);
    expect(element.querySelector('app-status-change [role="status"]')?.textContent).toContain(
      'Saving',
    );
    expect(updateButton().disabled).toBe(true);

    patch.flush(updated);
    await settle();
    expect(notice()?.textContent).toContain('"Renew permit" is now Waiting.');
    expect(element.querySelector('app-status-change [role="status"]')).toBeNull();

    await flushSummary();
    await flushList([updated]);
    expect(element.querySelector('tbody tr:first-child td:nth-child(3)')?.textContent?.trim()).toBe(
      'Waiting',
    );
    expect(notice()?.textContent).toContain('is now Waiting');
  });

  it('does not send a second update while one is being saved', async () => {
    await changeTo('Waiting');
    const patch = http.expectOne(STATUS_URL);

    updateButton().click();
    await settle();
    expect(http.match(STATUS_URL)).toHaveLength(0);

    patch.flush(updated);
    await settle();
    await flushSummary();
    await flushList([updated]);
  });

  it('explains a 409, locks the row until the data is reloaded and does not retry', async () => {
    await changeTo('Waiting');
    http.expectOne(STATUS_URL).flush(
      {
        title: 'Concurrency conflict.',
        detail: 'The request was changed by someone else. Reload it and try again.',
        currentStatus: 'Completed',
        currentRowVersion: 'AAAAAAAAB9G=',
      },
      { status: 409, statusText: 'Conflict' },
    );
    await settle();

    const message = notice();
    expect(message?.getAttribute('role')).toBe('alert');
    expect(message?.textContent).toContain('was changed by someone else');
    expect(message?.textContent).toContain('It is now Completed.');
    expect(message?.textContent).toContain('Reload the data');
    // No automatic retry, and nothing reloaded behind the user's back.
    http.expectNone(STATUS_URL);
    http.expectNone('/api/requests');
    http.expectNone('/api/requests/summary');
    expect(updateButton().disabled).toBe(true);
    expect(element.querySelector('app-status-change')?.textContent).toContain(
      'Reload the data to change',
    );

    const fresh: RequestItem = {
      ...item,
      status: 'Completed',
      rowVersion: 'AAAAAAAAB9G=',
      allowedNextStatuses: [],
    };
    (
      Array.from(notice()?.querySelectorAll('button') ?? []).find((b) =>
        b.textContent?.includes('Reload data'),
      ) as HTMLElement
    ).click();
    await settle();
    await flushSummary();
    await flushList([fresh]);

    expect(notice()).toBeNull();
    expect(element.querySelector('tbody tr:first-child td:nth-child(3)')?.textContent?.trim()).toBe(
      'Completed',
    );
    expect(element.querySelector('app-status-change')?.textContent).toContain('No further changes');
  });

  it('keeps the row editable after a 409 once the reload brings a new rowVersion', async () => {
    await changeTo('Waiting');
    http
      .expectOne(STATUS_URL)
      .flush({ title: 'Concurrency conflict.' }, { status: 409, statusText: 'Conflict' });
    await settle();

    (
      Array.from(notice()?.querySelectorAll('button') ?? []).find((b) =>
        b.textContent?.includes('Reload data'),
      ) as HTMLElement
    ).click();
    await settle();
    await flushSummary();
    await flushList([{ ...item, rowVersion: 'AAAAAAAAB9G=' }]);

    await changeTo('Waiting');
    expect(http.expectOne(STATUS_URL).request.body).toEqual({
      status: 'Waiting',
      rowVersion: 'AAAAAAAAB9G=',
    });
  });

  it.each([
    [
      422,
      { title: 'Status transition not allowed.', detail: 'Cannot move from New to Completed.' },
      'cannot be changed to that status',
      'Cannot move from New to Completed.',
      true,
    ],
    [
      404,
      { title: 'Request not found.', detail: 'No request with id 1 exists.' },
      'no longer exists',
      'Reload the data',
      true,
    ],
    [
      400,
      {
        title: 'One or more validation errors occurred.',
        errors: { 'X-User-Name': ['The X-User-Name header must be at most 100 characters.'] },
      },
      'was rejected',
      'at most 100 characters',
      false,
    ],
    [
      500,
      { title: 'An unexpected error occurred.' },
      'was not changed',
      'You can try again',
      false,
    ],
  ])(
    'shows the %i error without reloading anything',
    async (status, body, message, detail, canReload) => {
      await changeTo('Waiting');
      http.expectOne(STATUS_URL).flush(body, { status, statusText: 'Error' });
      await settle();

      const shown = notice();
      expect(shown?.getAttribute('role')).toBe('alert');
      expect(shown?.textContent).toContain(message);
      expect(shown?.textContent).toContain(detail);
      const labels = Array.from(shown?.querySelectorAll('button') ?? []).map((b) =>
        b.textContent?.trim(),
      );
      expect(labels.includes('Reload data')).toBe(canReload);
      http.expectNone('/api/requests');
      http.expectNone('/api/requests/summary');
      // The row is usable again (except after a 404, whose data is gone), so the user can choose again.
      expect(element.querySelector('app-status-change [role="status"]')).toBeNull();
    },
  );

  it('shows a network failure and lets the user try again', async () => {
    await changeTo('Waiting');
    http.expectOne(STATUS_URL).error(new ProgressEvent('error'));
    await settle();

    expect(notice()?.textContent).toContain('The server could not be reached.');
    updateButton().click();
    await settle();
    http.expectOne(STATUS_URL).flush(updated);
    await settle();
    await flushSummary();
    await flushList([updated]);
  });
});

describe('toLabel', () => {
  it('turns enum names into labels', () => {
    expect(toLabel('InProgress')).toBe('In progress');
    expect(toLabel('New')).toBe('New');
  });
});
