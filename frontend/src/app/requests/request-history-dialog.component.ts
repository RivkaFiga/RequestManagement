import { DatePipe } from '@angular/common';
import { Component, DestroyRef, inject, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { MatButtonModule } from '@angular/material/button';
import { MAT_DIALOG_DATA, MatDialogModule } from '@angular/material/dialog';
import { MatProgressBarModule } from '@angular/material/progress-bar';
import { Observable, Subject, catchError, map, of, switchMap } from 'rxjs';
import { ApiError } from '../core/api-error';
import { StatusHistoryEntry } from './request.models';
import { toLabel } from './request-labels';
import { RequestsApiService } from './requests-api.service';

/** Input of the dialog: the request whose history is shown. */
export interface RequestHistoryDialogData {
  readonly requestId: number;
  readonly title: string;
}

interface HistoryState {
  readonly status: 'loading' | 'loaded' | 'error';
  readonly entries: readonly StatusHistoryEntry[];
  readonly error: ApiError | null;
}

/**
 * The status changes of one request (plan §4.7, R5.7), loaded from `GET /api/requests/{id}/history`.
 * The API returns them newest first and the dialog shows them in that order.
 */
@Component({
  selector: 'app-request-history-dialog',
  imports: [DatePipe, MatButtonModule, MatDialogModule, MatProgressBarModule],
  templateUrl: './request-history-dialog.component.html',
  styleUrl: './request-history-dialog.component.scss',
})
export class RequestHistoryDialogComponent {
  protected readonly data = inject<RequestHistoryDialogData>(MAT_DIALOG_DATA);
  private readonly api = inject(RequestsApiService);

  private readonly load$ = new Subject<void>();
  protected readonly state = signal<HistoryState>({ status: 'loading', entries: [], error: null });
  protected readonly toLabel = toLabel;

  constructor() {
    this.load$
      .pipe(
        switchMap(() => this.fetch()),
        takeUntilDestroyed(inject(DestroyRef)),
      )
      .subscribe((state) => this.state.set(state));
    this.reload();
  }

  protected reload(): void {
    this.state.set({ status: 'loading', entries: [], error: null });
    this.load$.next();
  }

  private fetch(): Observable<HistoryState> {
    return this.api.getHistory(this.data.requestId).pipe(
      map((entries): HistoryState => ({ status: 'loaded', entries, error: null })),
      catchError((error: unknown) =>
        of<HistoryState>({
          status: 'error',
          entries: [],
          error: error instanceof ApiError ? error : new ApiError(0, 'Unexpected error.'),
        }),
      ),
    );
  }
}
