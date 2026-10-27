import { Component, computed, input, output, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatSelectModule } from '@angular/material/select';
import { ApiError } from '../core/api-error';
import { RequestItem, RequestStatus } from './request.models';
import { toLabel } from './request-labels';
import { readConflictDetails } from './requests-api.service';

/** What the page shows after a status change: one message, optionally with a way to reload the data. */
export interface StatusNotice {
  readonly kind: 'success' | 'error';
  readonly message: string;
  readonly detail: string | null;
  /** True when the data on screen is probably out of date, so reloading is the way forward. */
  readonly reload: boolean;
}

export function statusChangeSucceeded(updated: RequestItem): StatusNotice {
  return {
    kind: 'success',
    message: `"${updated.title}" is now ${toLabel(updated.status)}.`,
    detail: null,
    reload: false,
  };
}

/** Explains a failed status change (plan §4.7, R5.5). The change is never retried automatically. */
export function statusChangeFailed(request: RequestItem, error: ApiError): StatusNotice {
  const name = `"${request.title}"`;
  switch (error.status) {
    case 409: {
      const current = readConflictDetails(error);
      return {
        kind: 'error',
        message: `${name} was changed by someone else, so your change was not saved.`,
        detail:
          (current ? `It is now ${toLabel(current.currentStatus)}. ` : '') +
          'Reload the data to see the current values, then try again.',
        reload: true,
      };
    }
    case 404:
      return {
        kind: 'error',
        message: `${name} no longer exists, so your change was not saved.`,
        detail: 'Reload the data to see the current list.',
        reload: true,
      };
    case 422:
      return {
        kind: 'error',
        message: `${name} cannot be changed to that status.`,
        detail: error.detail ?? error.title,
        reload: true,
      };
    case 400: {
      const messages = Object.values(error.errors).flat();
      return {
        kind: 'error',
        message: `The change to ${name} was rejected.`,
        detail: messages.length > 0 ? messages.join(' ') : (error.detail ?? error.title),
        reload: false,
      };
    }
    default:
      return {
        kind: 'error',
        message: `${name} was not changed: ${error.title}`,
        detail: error.detail ?? 'Nothing was saved. You can try again.',
        reload: false,
      };
  }
}

/** True for the failures after which the row's `rowVersion` is known to be useless until the data is reloaded. */
export function isStaleFailure(error: ApiError): boolean {
  return error.status === 409 || error.status === 404;
}

/**
 * The status control of one row (plan §4.7): a choice limited to `allowedNextStatuses` and an explicit Update button.
 * It only reports the wish (`changeRequested`); the page calls the API, so a save outlives the row being re-rendered.
 */
@Component({
  selector: 'app-status-change',
  imports: [MatButtonModule, MatFormFieldModule, MatSelectModule],
  templateUrl: './status-change.component.html',
  styleUrl: './status-change.component.scss',
})
export class StatusChangeComponent {
  readonly request = input.required<RequestItem>();
  /** This row is being saved. */
  readonly saving = input(false);
  /** Another save or a reload is in progress: nothing can be submitted. */
  readonly disabled = input(false);
  /** The row's data is known to be out of date (after a 409 or 404): it must be reloaded first. */
  readonly stale = input(false);

  readonly changeRequested = output<RequestStatus>();

  protected readonly toLabel = toLabel;
  private readonly selected = signal<RequestStatus | null>(null);

  /** The chosen status, dropped when it is no longer allowed (the row was reloaded). */
  protected readonly choice = computed(() => {
    const selected = this.selected();
    return selected !== null && this.request().allowedNextStatuses.includes(selected)
      ? selected
      : null;
  });
  protected readonly locked = computed(() => this.saving() || this.disabled() || this.stale());

  protected choose(status: RequestStatus): void {
    this.selected.set(status);
  }

  protected update(): void {
    const choice = this.choice();
    if (choice === null || this.locked()) {
      return;
    }
    this.changeRequested.emit(choice);
  }
}
