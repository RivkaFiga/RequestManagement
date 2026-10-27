import { DestroyRef, Injectable, computed, inject, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import {
  Observable,
  Subject,
  catchError,
  debounceTime,
  distinctUntilChanged,
  map,
  of,
  switchMap,
} from 'rxjs';
import { ApiError, toApiError } from '../core/api-error';
import {
  PagedResult,
  RequestItem,
  RequestSearchParams,
  RequestSortField,
  SortDirection,
} from './request.models';
import { RequestsApiService } from './requests-api.service';

/** Same value as `DefaultPageSize` in the backend's `RequestSearchQuery`. */
const DEFAULT_PAGE_SIZE = 20;
export const SEARCH_DEBOUNCE_MS = 300;

/** The list query as the UI sees it. Every field is sent to the server; nothing is filtered or sorted client-side. */
export type RequestsListQuery = Required<Pick<RequestSearchParams, 'page' | 'pageSize'>> &
  Omit<RequestSearchParams, 'page' | 'pageSize'>;

/** Filters that reset the list to page 1 when they change (the search text is set with `setSearch`). */
export type RequestsListFilters = Pick<
  RequestSearchParams,
  'status' | 'priority' | 'organizationName' | 'assignedTo' | 'createdFrom' | 'createdTo'
>;

export type RequestsListStatus = 'loading' | 'loaded' | 'error';

export interface RequestsListState {
  readonly status: RequestsListStatus;
  /** The last page received. It stays while the next request is loading and is cleared on error. */
  readonly data: PagedResult<RequestItem> | null;
  readonly error: ApiError | null;
}

const INITIAL_QUERY: RequestsListQuery = { page: 1, pageSize: DEFAULT_PAGE_SIZE };

/**
 * State of the requests list (plan §4.7). Provide it on the page, not in root: each page owns its own query.
 * The search text is debounced; every other change applies immediately. Each query goes through `switchMap`,
 * so a newer query cancels the request still in flight.
 */
@Injectable()
export class RequestsListFacade {
  private readonly api = inject(RequestsApiService);

  private readonly queryState = signal<RequestsListQuery>(INITIAL_QUERY);
  private readonly listState = signal<RequestsListState>({
    status: 'loading',
    data: null,
    error: null,
  });
  private readonly searchInput$ = new Subject<string>();
  private readonly load$ = new Subject<RequestsListQuery>();

  readonly query = this.queryState.asReadonly();
  readonly state = this.listState.asReadonly();
  readonly loading = computed(() => this.listState().status === 'loading');
  readonly error = computed(() => this.listState().error);
  readonly data = computed(() => this.listState().data);
  readonly items = computed<readonly RequestItem[]>(() => this.listState().data?.items ?? []);
  /** True when a request finished successfully and returned no items. */
  readonly empty = computed(() => {
    const { status, data } = this.listState();
    return status === 'loaded' && (data?.items.length ?? 0) === 0;
  });

  constructor() {
    const destroyRef = inject(DestroyRef);

    this.load$
      .pipe(
        switchMap((query) => this.fetch(query)),
        takeUntilDestroyed(destroyRef),
      )
      .subscribe((state) => this.listState.set(state));

    this.searchInput$
      .pipe(
        debounceTime(SEARCH_DEBOUNCE_MS),
        distinctUntilChanged(),
        takeUntilDestroyed(destroyRef),
      )
      .subscribe((search) => {
        if (search !== (this.queryState().search ?? '')) {
          this.apply({ ...this.queryState(), search, page: 1 });
        }
      });

    this.apply(INITIAL_QUERY);
  }

  /** Debounced: one request per typing pause. */
  setSearch(search: string): void {
    this.searchInput$.next(search);
  }

  /** Replaces the filters and goes back to page 1. */
  setFilters(filters: RequestsListFilters): void {
    const { search, sortBy, sortDirection, pageSize } = this.queryState();
    this.apply({ ...filters, search, sortBy, sortDirection, pageSize, page: 1 });
  }

  setSort(sortBy: RequestSortField | undefined, sortDirection: SortDirection | undefined): void {
    this.apply({ ...this.queryState(), sortBy, sortDirection });
  }

  setPage(page: number, pageSize: number = this.queryState().pageSize): void {
    const samePageSize = pageSize === this.queryState().pageSize;
    this.apply({ ...this.queryState(), page: samePageSize ? page : 1, pageSize });
  }

  /** Re-runs the current query (also the retry action after an error). */
  refresh(): void {
    this.apply(this.queryState());
  }

  private apply(query: RequestsListQuery): void {
    this.queryState.set(query);
    this.listState.update((state) => ({ status: 'loading', data: state.data, error: null }));
    this.load$.next(query);
  }

  private fetch(query: RequestsListQuery): Observable<RequestsListState> {
    return this.api.search(query).pipe(
      map((data): RequestsListState => ({ status: 'loaded', data, error: null })),
      catchError((error: unknown) =>
        of<RequestsListState>({ status: 'error', data: null, error: toApiError(error) }),
      ),
    );
  }
}
