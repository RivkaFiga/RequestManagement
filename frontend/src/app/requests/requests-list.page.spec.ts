import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, TestRequest, provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
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

function page(items: readonly RequestItem[], pageNumber = 1, totalCount = items.length): PagedResult<RequestItem> {
  return { items, page: pageNumber, pageSize: 20, totalCount, totalPages: Math.ceil(totalCount / 20) };
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
      providers: [provideHttpClient(withInterceptors([httpErrorInterceptor])), provideHttpClientTesting()],
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(RequestsListPage);
    element = fixture.nativeElement as HTMLElement;
    await settle();
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
    const cells = Array.from(element.querySelectorAll('tbody tr:first-child td')).map((c) => c.textContent?.trim());
    expect(cells.slice(0, 5)).toEqual(['Renew permit', 'Acme', 'In progress', 'High', '—']);
    expect(element.querySelector('.mat-mdc-paginator-range-label')?.textContent).toContain('of 41');
  });

  it('shows the empty state', async () => {
    lastRequest().flush(page([]));
    await settle();

    expect(element.querySelector('[role="status"]')?.textContent).toContain('No requests match');
    expect(element.querySelector('table')).toBeNull();
  });

  it('shows the error and retries the same query', async () => {
    lastRequest().flush({ title: 'Boom', detail: 'Database unavailable' }, { status: 500, statusText: 'Server Error' });
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
    expect(new Date(params.get('createdFrom') as string).getTime()).toBe(new Date('2026-10-01T00:00:00').getTime());
    expect(new Date(params.get('createdTo') as string).getTime()).toBe(new Date('2026-10-06T00:00:00').getTime());
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

    expect((element.querySelector('button[type="submit"]') as HTMLButtonElement).disabled).toBe(true);
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

describe('toLabel', () => {
  it('turns enum names into labels', () => {
    expect(toLabel('InProgress')).toBe('In progress');
    expect(toLabel('New')).toBe('New');
  });
});
