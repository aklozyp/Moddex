import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { fakeAsync, TestBed, tick } from '@angular/core/testing';
import { HttpClient, provideHttpClient, withInterceptors } from '@angular/common/http';
import { Router } from '@angular/router';
import { firstValueFrom } from 'rxjs';

import { authInterceptor } from '../interceptors/auth.interceptor';
import { AuthService } from './auth.service';
import { ServerService } from './server-service';

const BASE_ORIGIN = 'http://backend.test';
const SETTINGS_ENDPOINT = BASE_ORIGIN + '/api/v1/serverSettings';
const LOGIN_ENDPOINT = BASE_ORIGIN + '/api/v1/auth/login';
const STORED_TOKEN = 'stored-session-token';

describe('AuthService', () => {
  let service: AuthService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([authInterceptor])),
        provideHttpClientTesting(),
        { provide: ServerService, useValue: { getCurrentOrigin: () => BASE_ORIGIN } },
        { provide: Router, useValue: { navigate: jasmine.createSpy('navigate') } }
      ]
    });
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    // Der Timeout-Test bricht die Anfrage bewusst ab; abgebrochene Requests
    // sollen verify() nicht als Fehler melden.
    httpMock.verify({ ignoreCancelled: true });
    localStorage.clear();
  });

  function createServiceWithToken(token: string | null): AuthService {
    if (token) {
      localStorage.setItem('auth_token', token);
    }
    service = TestBed.inject(AuthService);
    return service;
  }

  it('stays unauthenticated without a stored token and validates nothing', async () => {
    const authService = createServiceWithToken(null);

    expect(authService.isAuthenticated()).toBeFalse();
    expect(authService.isChecking()).toBeFalse();

    const valid = await firstValueFrom(authService.validateStoredToken());

    expect(valid).toBeFalse();
    expect(authService.isAuthenticated()).toBeFalse();
    httpMock.expectNone(SETTINGS_ENDPOINT);
  });

  it('authenticates without leaving the checking state early when the token is valid', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    expect(authService.isChecking()).toBeTrue();
    expect(authService.isAuthenticated()).toBeFalse();

    const validated = firstValueFrom(authService.validateStoredToken());
    const request = httpMock.expectOne(SETTINGS_ENDPOINT);
    expect(request.request.method).toBe('GET');
    expect(request.request.headers.get('Authorization')).toBe(`Bearer ${STORED_TOKEN}`);
    request.flush({});

    expect(await validated).toBeTrue();
    expect(authService.isAuthenticated()).toBeTrue();
    expect(authService.isChecking()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);
  });

  it('removes the token and falls back to the login state on 401', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const validated = firstValueFrom(authService.validateStoredToken());
    httpMock
      .expectOne(SETTINGS_ENDPOINT)
      .flush({ message: 'expired' }, { status: 401, statusText: 'Unauthorized' });

    expect(await validated).toBeFalse();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(authService.isUnreachable()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBeNull();
  });

  it('removes the token and falls back to the login state on 403', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const validated = firstValueFrom(authService.validateStoredToken());
    httpMock
      .expectOne(SETTINGS_ENDPOINT)
      .flush({ message: 'forbidden' }, { status: 403, statusText: 'Forbidden' });

    expect(await validated).toBeFalse();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBeNull();
  });

  it('keeps the token and reports the backend as unreachable on network errors', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const validated = firstValueFrom(authService.validateStoredToken());
    httpMock.expectOne(SETTINGS_ENDPOINT).error(new ProgressEvent('network error'));

    expect(await validated).toBeFalse();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(authService.isUnreachable()).toBeTrue();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);
  });

  it('reports the backend as unreachable when the validation call times out', fakeAsync(() => {
    const authService = createServiceWithToken(STORED_TOKEN);
    let result: boolean | undefined;

    authService.validateStoredToken().subscribe(valid => (result = valid));

    // Die Anfrage bleibt bewusst unbeantwortet; der Ablauf-Timeout greift.
    httpMock.expectOne(SETTINGS_ENDPOINT);
    tick(10_000);

    expect(result).toBeFalse();
    expect(authService.isUnreachable()).toBeTrue();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);
  }));

  it('keeps the token on server errors and validates successfully on retry', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const firstAttempt = firstValueFrom(authService.validateStoredToken());
    httpMock
      .expectOne(SETTINGS_ENDPOINT)
      .flush({ message: 'boom' }, { status: 500, statusText: 'Internal Server Error' });

    expect(await firstAttempt).toBeFalse();
    expect(authService.isUnreachable()).toBeTrue();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);

    const retry = firstValueFrom(authService.validateStoredToken());
    const retryRequest = httpMock.expectOne(SETTINGS_ENDPOINT);
    expect(retryRequest.request.headers.get('Authorization')).toBe(`Bearer ${STORED_TOKEN}`);
    retryRequest.flush({});

    expect(await retry).toBeTrue();
    expect(authService.isAuthenticated()).toBeTrue();
  });

  it('shares a single request between concurrent validations', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const first = firstValueFrom(authService.validateStoredToken());
    const second = firstValueFrom(authService.validateStoredToken());

    const requests = httpMock.match(SETTINGS_ENDPOINT);
    expect(requests.length).toBe(1);
    requests[0].flush({});

    expect(await first).toBeTrue();
    expect(await second).toBeTrue();
  });

  it('answers an already authenticated service without a further request', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const initial = firstValueFrom(authService.validateStoredToken());
    httpMock.expectOne(SETTINGS_ENDPOINT).flush({});
    expect(await initial).toBeTrue();

    const valid = await firstValueFrom(authService.validateStoredToken());

    expect(valid).toBeTrue();
    expect(authService.isAuthenticated()).toBeTrue();
    httpMock.expectNone(SETTINGS_ENDPOINT);
  });

  it('stores the token and becomes authenticated after a successful login', () => {
    const authService = createServiceWithToken(null);

    authService.login('secret-password').subscribe();
    const request = httpMock.expectOne(LOGIN_ENDPOINT);
    expect(request.request.method).toBe('POST');
    expect(request.request.body).toEqual({ password: 'secret-password' });
    request.flush({ token: 'issued-token' });

    expect(localStorage.getItem('auth_token')).toBe('issued-token');
    expect(authService.isAuthenticated()).toBeTrue();
  });

  it('keeps the unauthenticated state when the login fails', () => {
    const authService = createServiceWithToken(null);

    authService.login('wrong-password').subscribe({ error: () => undefined });
    httpMock
      .expectOne(LOGIN_ENDPOINT)
      .flush({ message: 'bad credentials' }, { status: 401, statusText: 'Unauthorized' });

    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(authService.isAuthenticated()).toBeFalse();
  });

  it('clears the token on logout', () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    authService.logout();

    expect(localStorage.getItem('auth_token')).toBeNull();
    expect(authService.isAuthenticated()).toBeFalse();
  });

  it('does not let an older failed validation override a login completed in the meantime', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const staleValidation = firstValueFrom(authService.validateStoredToken());

    authService.login('secret-password').subscribe();
    const loginRequest = httpMock.expectOne(LOGIN_ENDPOINT);
    loginRequest.flush({ token: 'fresh-token' });
    expect(authService.isAuthenticated()).toBeTrue();

    httpMock
      .expectOne(SETTINGS_ENDPOINT)
      .flush({ message: 'expired' }, { status: 401, statusText: 'Unauthorized' });

    expect(await staleValidation).toBeTrue();
    expect(authService.isAuthenticated()).toBeTrue();
    expect(localStorage.getItem('auth_token')).toBe('fresh-token');
  });

  it('does not let a late validation success override a logout completed in the meantime', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const staleValidation = firstValueFrom(authService.validateStoredToken());

    authService.logout();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBeNull();

    httpMock.expectOne(SETTINGS_ENDPOINT).flush({});

    expect(await staleValidation).toBeFalse();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBeNull();
  });

  it('does not let a late validation failure report the backend as unreachable after a logout', async () => {
    const authService = createServiceWithToken(STORED_TOKEN);

    const staleValidation = firstValueFrom(authService.validateStoredToken());

    authService.logout();
    expect(localStorage.getItem('auth_token')).toBeNull();

    httpMock.expectOne(SETTINGS_ENDPOINT).error(new ProgressEvent('network error'));

    expect(await staleValidation).toBeFalse();
    // Der Prüfungsfehler läuft in einen inzwischen erfolgten Logout: Der
    // unauthentifizierte Zustand bleibt bestehen und wird nicht zu
    // 'unreachable' umgebogen.
    expect(authService.isUnreachable()).toBeFalse();
    expect(authService.isAuthenticated()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBeNull();
  });
});
