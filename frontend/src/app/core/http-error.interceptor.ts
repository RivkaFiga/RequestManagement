import { HttpErrorResponse, HttpInterceptorFn } from '@angular/common/http';
import { catchError, throwError } from 'rxjs';
import { ApiError } from './api-error';

/** Converts every failed HTTP call into an `ApiError`, so callers never see `HttpErrorResponse`. */
export const httpErrorInterceptor: HttpInterceptorFn = (req, next) =>
  next(req).pipe(
    catchError((error: unknown) =>
      throwError(() =>
        error instanceof HttpErrorResponse
          ? ApiError.fromResponse(error.status, error.error)
          : error,
      ),
    ),
  );
