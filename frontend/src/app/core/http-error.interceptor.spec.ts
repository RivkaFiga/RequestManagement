import { HttpClient, provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { ApiError } from './api-error';
import { httpErrorInterceptor } from './http-error.interceptor';

describe('httpErrorInterceptor', () => {
  let http: HttpClient;
  let controller: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([httpErrorInterceptor])),
        provideHttpClientTesting(),
      ],
    });
    http = TestBed.inject(HttpClient);
    controller = TestBed.inject(HttpTestingController);
  });

  afterEach(() => controller.verify());

  function failWith(status: number, body: string | object): ApiError {
    let caught: unknown;
    http.get('/api/requests').subscribe({ error: (e: unknown) => (caught = e) });
    controller.expectOne('/api/requests').flush(body, { status, statusText: 'x' });
    return caught as ApiError;
  }

  it('maps a ProblemDetails 409 including its extension members', () => {
    const error = failWith(409, {
      title: 'Concurrency conflict.',
      detail: 'Changed by someone else.',
      status: 409,
      traceId: 't-1',
      currentStatus: 'InProgress',
      currentRowVersion: 'AAAA',
    });
    expect(error).toBeInstanceOf(ApiError);
    expect(error.status).toBe(409);
    expect(error.title).toBe('Concurrency conflict.');
    expect(error.detail).toBe('Changed by someone else.');
    expect(error.traceId).toBe('t-1');
    expect(error.extensions).toEqual({ currentStatus: 'InProgress', currentRowVersion: 'AAAA' });
  });

  it('maps validation errors by field', () => {
    const error = failWith(400, { title: 'Invalid.', errors: { pageSize: ['Too large.'] } });
    expect(error.errors).toEqual({ pageSize: ['Too large.'] });
  });

  it('maps a non-JSON failure to a generic ApiError', () => {
    const error = failWith(502, '<html>Bad gateway</html>');
    expect(error.status).toBe(502);
    expect(error.title).toBe('Request failed (502).');
  });

  it('maps a network failure to status 0', () => {
    let caught: unknown;
    http.get('/api/requests').subscribe({ error: (e: unknown) => (caught = e) });
    controller.expectOne('/api/requests').error(new ProgressEvent('error'));
    expect((caught as ApiError).status).toBe(0);
  });
});
