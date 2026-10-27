import { Component, DestroyRef, inject, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressBarModule } from '@angular/material/progress-bar';
import { Observable, Subject, catchError, map, of, switchMap } from 'rxjs';
import { ApiError, toApiError } from '../core/api-error';
import { RequestSummary } from './request.models';
import { toLabel } from './request-labels';
import { RequestsApiService } from './requests-api.service';

interface SummaryState {
  readonly status: 'loading' | 'loaded' | 'error';
  /** The last numbers received. They stay while the next request is loading and are cleared on error. */
  readonly summary: RequestSummary | null;
  readonly error: ApiError | null;
}

/**
 * Shows the counts of `GET /api/requests/summary` (plan §4.7). The numbers are global and ignore the list filters
 * (assumption A4), so filter changes do not reload the panel. Nothing is recomputed here: the API lists every
 * status and priority, in enum order. The page calls `refresh()` after a successful status update (T-306).
 */
@Component({
  selector: 'app-summary-panel',
  imports: [MatButtonModule, MatProgressBarModule],
  templateUrl: './summary-panel.component.html',
  styleUrl: './summary-panel.component.scss',
})
export class SummaryPanelComponent {
  private readonly api = inject(RequestsApiService);

  private readonly load$ = new Subject<void>();
  protected readonly state = signal<SummaryState>({
    status: 'loading',
    summary: null,
    error: null,
  });
  protected readonly toLabel = toLabel;

  constructor() {
    this.load$
      .pipe(
        switchMap(() => this.fetch()),
        takeUntilDestroyed(inject(DestroyRef)),
      )
      .subscribe((state) => this.state.set(state));
    this.refresh();
  }

  /** Reloads the summary. The last numbers stay visible while the request is in flight. */
  refresh(): void {
    this.state.update((state) => ({ status: 'loading', summary: state.summary, error: null }));
    this.load$.next();
  }

  private fetch(): Observable<SummaryState> {
    return this.api.getSummary().pipe(
      map((summary): SummaryState => ({ status: 'loaded', summary, error: null })),
      catchError((error: unknown) =>
        of<SummaryState>({ status: 'error', summary: null, error: toApiError(error) }),
      ),
    );
  }
}
