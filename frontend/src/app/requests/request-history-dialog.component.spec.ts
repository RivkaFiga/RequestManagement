import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { MAT_DIALOG_DATA } from '@angular/material/dialog';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { httpErrorInterceptor } from '../core/http-error.interceptor';
import { StatusHistoryEntry } from './request.models';
import { RequestHistoryDialogComponent, RequestHistoryDialogData } from './request-history-dialog.component';

const entries: readonly StatusHistoryEntry[] = [
  {
    id: 12,
    requestId: 7,
    previousStatus: 'InProgress',
    newStatus: 'Waiting',
    changedAt: '2026-10-02T09:30:00Z',
    changedBy: 'dana',
  },
  {
    id: 11,
    requestId: 7,
    previousStatus: 'New',
    newStatus: 'InProgress',
    changedAt: '2026-10-01T08:00:00Z',
    changedBy: 'anonymous',
  },
];

describe('RequestHistoryDialogComponent', () => {
  let fixture: ComponentFixture<RequestHistoryDialogComponent>;
  let http: HttpTestingController;
  let element: HTMLElement;

  const settle = async (): Promise<void> => {
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  };
  const historyUrl = '/api/requests/7/history';

  beforeEach(async () => {
    const data: RequestHistoryDialogData = { requestId: 7, title: 'Renew permit' };
    TestBed.configureTestingModule({
      imports: [RequestHistoryDialogComponent],
      providers: [
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
        { provide: MAT_DIALOG_DATA, useValue: data },
      ],
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(RequestHistoryDialogComponent);
    element = fixture.nativeElement as HTMLElement;
    await settle();
  });

  afterEach(() => http.verify());

  it('shows the loading indicator while the history is requested', () => {
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();
    expect(element.textContent).toContain('#7 · Renew permit');
    http.expectOne(historyUrl).flush([]);
  });

  it('lists the entries in the order the API returns them', async () => {
    http.expectOne(historyUrl).flush(entries);
    await settle();

    expect(element.querySelector('mat-progress-bar')).toBeNull();
    const rows = Array.from(element.querySelectorAll('[data-testid="history-row"]')).map((row) =>
      Array.from(row.querySelectorAll('td')).map((cell) => cell.textContent?.trim()),
    );
    expect(rows).toHaveLength(2);
    expect(rows[0].slice(1)).toEqual(['In progress → Waiting', 'dana']);
    expect(rows[1].slice(1)).toEqual(['New → In progress', 'anonymous']);
  });

  it('shows the empty state when the request never changed', async () => {
    http.expectOne(historyUrl).flush([]);
    await settle();

    expect(element.querySelector('[data-testid="history-empty"]')).toBeTruthy();
    expect(element.querySelector('table')).toBeNull();
  });

  it('shows the error and loads the history again on Retry', async () => {
    http
      .expectOne(historyUrl)
      .flush({ title: 'Request not found.', detail: 'No request with id 7 exists.' }, { status: 404, statusText: 'Not Found' });
    await settle();

    const error = element.querySelector('[data-testid="history-error"]');
    expect(error?.textContent).toContain('Request not found.');
    expect(error?.textContent).toContain('No request with id 7 exists.');

    (error?.querySelector('button') as HTMLButtonElement).click();
    await settle();
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();
    http.expectOne(historyUrl).flush(entries);
    await settle();

    expect(element.querySelector('[data-testid="history-error"]')).toBeNull();
    expect(element.querySelectorAll('[data-testid="history-row"]')).toHaveLength(2);
  });
});
