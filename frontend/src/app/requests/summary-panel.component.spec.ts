import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { httpErrorInterceptor } from '../core/http-error.interceptor';
import { RequestSummary } from './request.models';
import { SummaryPanelComponent } from './summary-panel.component';

const SUMMARY_URL = '/api/requests/summary';

const summary: RequestSummary = {
  total: 100,
  byStatus: [
    { status: 'New', count: 40 },
    { status: 'InProgress', count: 30 },
    { status: 'Waiting', count: 0 },
    { status: 'Completed', count: 30 },
  ],
  byPriority: [
    { priority: 'Low', count: 25 },
    { priority: 'Medium', count: 50 },
    { priority: 'High', count: 25 },
  ],
  generatedAt: '2026-10-25T08:00:00Z',
};

describe('SummaryPanelComponent', () => {
  let fixture: ComponentFixture<SummaryPanelComponent>;
  let http: HttpTestingController;
  let element: HTMLElement;

  const settle = async (): Promise<void> => {
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
  };
  const items = (group: string): string[] =>
    Array.from(element.querySelectorAll(`[data-group="${group}"]`)).map(
      (i) => `${i.querySelector('dt')?.textContent}: ${i.querySelector('dd')?.textContent}`,
    );

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [SummaryPanelComponent],
      providers: [provideHttpClient(withInterceptors([httpErrorInterceptor])), provideHttpClientTesting()],
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(SummaryPanelComponent);
    element = fixture.nativeElement as HTMLElement;
    await settle();
  });

  afterEach(() => http.verify());

  it('shows the loading indicator until the summary arrives', async () => {
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();

    http.expectOne(SUMMARY_URL).flush(summary);
    await settle();

    expect(element.querySelector('mat-progress-bar')).toBeNull();
  });

  it('shows the total and both aggregations exactly as the API returned them', async () => {
    http.expectOne(SUMMARY_URL).flush(summary);
    await settle();

    expect(element.querySelector('[data-testid="total"]')?.textContent).toBe('100');
    expect(items('status')).toEqual(['New: 40', 'In progress: 30', 'Waiting: 0', 'Completed: 30']);
    expect(items('priority')).toEqual(['Low: 25', 'Medium: 50', 'High: 25']);
  });

  it('shows the error with a retry that loads the summary again', async () => {
    http.expectOne(SUMMARY_URL).flush({ title: 'Boom' }, { status: 500, statusText: 'Server Error' });
    await settle();

    expect(element.querySelector('[role="alert"]')?.textContent).toContain('Boom');
    expect(element.querySelector('[data-group]')).toBeNull();

    (element.querySelector('[role="alert"] button') as HTMLElement).click();
    await settle();
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();
    http.expectOne(SUMMARY_URL).flush(summary);
    await settle();

    expect(element.querySelector('[role="alert"]')).toBeNull();
    expect(items('priority')).toHaveLength(3);
  });

  it('refresh() keeps the old numbers while loading, then shows the new ones', async () => {
    http.expectOne(SUMMARY_URL).flush(summary);
    await settle();

    fixture.componentInstance.refresh();
    await settle();
    expect(element.querySelector('mat-progress-bar')).toBeTruthy();
    expect(element.querySelector('[data-testid="total"]')?.textContent).toBe('100');

    http.expectOne(SUMMARY_URL).flush({ ...summary, total: 101 });
    await settle();
    expect(element.querySelector('[data-testid="total"]')?.textContent).toBe('101');
  });

  it('cancels the request in flight when refreshed again', async () => {
    const first = http.expectOne(SUMMARY_URL);
    fixture.componentInstance.refresh();
    expect(first.cancelled).toBe(true);
    http.expectOne(SUMMARY_URL).flush(summary);
  });
});
