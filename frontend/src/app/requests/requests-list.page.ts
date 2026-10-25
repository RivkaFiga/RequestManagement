import { DatePipe } from '@angular/common';
import { Component, DestroyRef, inject, signal, viewChild } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { AbstractControl, FormBuilder, ReactiveFormsModule, ValidationErrors, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog, MatDialogModule } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatPaginatorModule, PageEvent } from '@angular/material/paginator';
import { MatProgressBarModule } from '@angular/material/progress-bar';
import { MatSelectModule } from '@angular/material/select';
import { MatSortModule, Sort } from '@angular/material/sort';
import { MatTableModule } from '@angular/material/table';
import { finalize } from 'rxjs';
import { ApiError } from '../core/api-error';
import {
  REQUEST_PRIORITIES,
  REQUEST_SORT_FIELDS,
  REQUEST_STATUSES,
  RequestItem,
  RequestPriority,
  RequestSortField,
  RequestStatus,
} from './request.models';
import { RequestHistoryDialogComponent, RequestHistoryDialogData } from './request-history-dialog.component';
import { toLabel } from './request-labels';
import { RequestsApiService } from './requests-api.service';
import { RequestsListFacade, RequestsListFilters } from './requests-list.facade';
import {
  StatusChangeComponent,
  StatusNotice,
  isStaleFailure,
  statusChangeFailed,
  statusChangeSucceeded,
} from './status-change.component';
import { SummaryPanelComponent } from './summary-panel.component';

/** Limits of the API (`RequestSearchQuery`): the search needs 2 to 100 characters. */
const SEARCH_MIN_LENGTH = 2;
const SEARCH_MAX_LENGTH = 100;
const ORGANIZATION_MAX_LENGTH = 200;
const ASSIGNED_TO_MAX_LENGTH = 100;

/** Same as the backend default (`createdAt`, descending), so the header arrow matches what the server returns. */
const DEFAULT_SORT: Sort = { active: 'createdAt', direction: 'desc' };

const PAGE_SIZE_OPTIONS = [10, 20, 50, 100];

/** A single character is rejected by the API (400), so it is never sent. Blank is fine: it clears the search. */
function searchLength(control: AbstractControl<string>): ValidationErrors | null {
  const length = control.value.trim().length;
  return length > 0 && length < SEARCH_MIN_LENGTH ? { minlength: true } : null;
}

/** `createdFrom` must not be later than `createdTo` (the dates are `yyyy-MM-dd`, so strings compare correctly). */
function dateRange(group: AbstractControl): ValidationErrors | null {
  const { createdFrom, createdTo } = group.value as { createdFrom: string; createdTo: string };
  return createdFrom && createdTo && createdFrom > createdTo ? { dateRange: true } : null;
}

export { toLabel };

/**
 * The requests list page (plan §4.7). It only renders the facade state and forwards user input to it:
 * filtering, sorting and paging all happen on the server.
 */
@Component({
  selector: 'app-requests-list-page',
  imports: [
    DatePipe,
    ReactiveFormsModule,
    MatButtonModule,
    MatDialogModule,
    MatFormFieldModule,
    MatInputModule,
    MatPaginatorModule,
    MatProgressBarModule,
    MatSelectModule,
    MatSortModule,
    MatTableModule,
    StatusChangeComponent,
    SummaryPanelComponent,
  ],
  providers: [RequestsListFacade],
  templateUrl: './requests-list.page.html',
  styleUrl: './requests-list.page.scss',
})
export class RequestsListPage {
  protected readonly facade = inject(RequestsListFacade);
  private readonly api = inject(RequestsApiService);
  private readonly dialog = inject(MatDialog);
  private readonly destroyRef = inject(DestroyRef);
  private readonly fb = inject(FormBuilder).nonNullable;
  private readonly summaryPanel = viewChild(SummaryPanelComponent);

  /** Id of the request being saved. Only one save runs at a time, which also prevents a double submit. */
  protected readonly savingId = signal<number | null>(null);
  protected readonly notice = signal<StatusNotice | null>(null);
  /** `rowVersion` per request id that got a 409 or 404: the row stays locked until the reload brings a new one. */
  private readonly staleVersions = signal<ReadonlyMap<number, string>>(new Map());

  protected readonly statuses = REQUEST_STATUSES;
  protected readonly priorities = REQUEST_PRIORITIES;
  protected readonly pageSizeOptions = PAGE_SIZE_OPTIONS;
  protected readonly defaultSort = DEFAULT_SORT;
  protected readonly searchMaxLength = SEARCH_MAX_LENGTH;
  protected readonly organizationMaxLength = ORGANIZATION_MAX_LENGTH;
  protected readonly assignedToMaxLength = ASSIGNED_TO_MAX_LENGTH;
  protected readonly toLabel = toLabel;
  protected readonly columns = [
    'title',
    'organizationName',
    'status',
    'priority',
    'assignedTo',
    'createdAt',
    'updatedAt',
    'change',
    'history',
  ] as const;

  protected readonly searchControl = this.fb.control('', [searchLength]);

  protected readonly filters = this.fb.group(
    {
      status: this.fb.control<RequestStatus[]>([]),
      priority: this.fb.control<RequestPriority[]>([]),
      organizationName: this.fb.control('', [Validators.maxLength(ORGANIZATION_MAX_LENGTH)]),
      assignedTo: this.fb.control('', [Validators.maxLength(ASSIGNED_TO_MAX_LENGTH)]),
      createdFrom: this.fb.control(''),
      createdTo: this.fb.control(''),
    },
    { validators: [dateRange] },
  );

  constructor() {
    this.searchControl.valueChanges.pipe(takeUntilDestroyed(inject(DestroyRef))).subscribe((value) => {
      if (this.searchControl.valid) {
        this.facade.setSearch(value.trim());
      }
    });
  }

  protected applyFilters(): void {
    if (this.filters.invalid) {
      return;
    }
    const { status, priority, organizationName, assignedTo, createdFrom, createdTo } = this.filters.getRawValue();
    const filters: RequestsListFilters = {
      status,
      priority,
      organizationName: organizationName.trim(),
      assignedTo: assignedTo.trim(),
      createdFrom: createdFrom ? new Date(`${createdFrom}T00:00:00`) : undefined,
      createdTo: createdTo ? endOfDay(createdTo) : undefined,
    };
    this.facade.setFilters(filters);
  }

  protected clearFilters(): void {
    this.filters.reset();
    this.applyFilters();
  }

  protected onSort(sort: Sort): void {
    const field = (REQUEST_SORT_FIELDS as readonly string[]).includes(sort.active)
      ? (sort.active as RequestSortField)
      : undefined;
    this.facade.setSort(field, sort.direction === '' ? undefined : sort.direction);
  }

  protected onPage(event: PageEvent): void {
    this.facade.setPage(event.pageIndex + 1, event.pageSize);
  }

  protected openHistory(request: RequestItem): void {
    const data: RequestHistoryDialogData = { requestId: request.id, title: request.title };
    this.dialog.open(RequestHistoryDialogComponent, { data, width: '640px', maxWidth: '95vw' });
  }

  protected isStale(row: RequestItem): boolean {
    return this.staleVersions().get(row.id) === row.rowVersion;
  }

  /**
   * `PATCH /api/requests/{id}/status` with the `rowVersion` the row was loaded with. After a success the list and
   * the summary are reloaded. A 409 is never retried: the user reloads the data and decides again (R2.5, R5.5).
   */
  protected changeStatus(request: RequestItem, status: RequestStatus): void {
    if (this.savingId() !== null) {
      return;
    }
    this.savingId.set(request.id);
    this.notice.set(null);

    this.api
      .updateStatus(request.id, { status, rowVersion: request.rowVersion })
      .pipe(
        finalize(() => this.savingId.set(null)),
        takeUntilDestroyed(this.destroyRef),
      )
      .subscribe({
        next: (updated) => {
          this.notice.set(statusChangeSucceeded(updated));
          this.reload();
        },
        error: (error: unknown) => {
          const apiError = error instanceof ApiError ? error : new ApiError(0, 'Unexpected error.');
          if (isStaleFailure(apiError)) {
            this.staleVersions.update((stale) => new Map(stale).set(request.id, request.rowVersion));
          }
          this.notice.set(statusChangeFailed(request, apiError));
        },
      });
  }

  /** The "Reload data" action of a notice. */
  protected reloadFromNotice(): void {
    this.notice.set(null);
    this.reload();
  }

  protected dismissNotice(): void {
    this.notice.set(null);
  }

  private reload(): void {
    this.facade.refresh();
    this.summaryPanel()?.refresh();
  }
}

/** `createdTo` is exclusive on the server, so "up to and including the 5th" is the start of the 6th (local time). */
function endOfDay(date: string): Date {
  const result = new Date(`${date}T00:00:00`);
  result.setDate(result.getDate() + 1);
  return result;
}
