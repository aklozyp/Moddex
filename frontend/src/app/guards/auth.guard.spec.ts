import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { ActivatedRouteSnapshot, RouterStateSnapshot, UrlTree } from '@angular/router';
import { provideRouter } from '@angular/router';
import { firstValueFrom, Observable } from 'rxjs';

import { authInterceptor } from '../interceptors/auth.interceptor';
import { authGuard } from './auth.guard';
import { AuthService } from '../services/auth.service';
import { ServerService } from '../services/server-service';

const BASE_ORIGIN = 'http://backend.test';
const SETTINGS_ENDPOINT = BASE_ORIGIN + '/api/v1/serverSettings';
const STORED_TOKEN = 'stored-session-token';
// Der Guard reicht das ursprüngliche Ziel als returnUrl an /login weiter.
const LOGIN_REDIRECT_FROM_HOME = '/login?returnUrl=%2Fhome';

describe('authGuard', () => {
  let httpMock: HttpTestingController;
  let authService: AuthService;

  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({
      providers: [
        provideRouter([]),
        provideHttpClient(withInterceptors([authInterceptor])),
        provideHttpClientTesting(),
        { provide: ServerService, useValue: { getCurrentOrigin: () => BASE_ORIGIN } }
      ]
    });
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  function injectAuthService(): AuthService {
    authService = TestBed.inject(AuthService);
    return authService;
  }

  function runGuard(): Observable<boolean | UrlTree> {
    return TestBed.runInInjectionContext(() =>
      authGuard({} as ActivatedRouteSnapshot, { url: '/home' } as RouterStateSnapshot)
    ) as Observable<boolean | UrlTree>;
  }

  it('waits for the server-side check and allows navigation for a valid token', async () => {
    localStorage.setItem('auth_token', STORED_TOKEN);
    injectAuthService();

    const pending = firstValueFrom(runGuard());
    const request = httpMock.expectOne(SETTINGS_ENDPOINT);
    expect(request.request.headers.get('Authorization')).toBe(`Bearer ${STORED_TOKEN}`);
    request.flush({});

    expect(await pending).toBeTrue();
    expect(authService.isAuthenticated()).toBeTrue();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);
  });

  it('redirects to /login and removes the token when the backend rejects it with 401', async () => {
    localStorage.setItem('auth_token', STORED_TOKEN);
    injectAuthService();

    const pending = firstValueFrom(runGuard());
    httpMock
      .expectOne(SETTINGS_ENDPOINT)
      .flush({ message: 'expired' }, { status: 401, statusText: 'Unauthorized' });

    const result = await pending;

    expect(result instanceof UrlTree).toBeTrue();
    expect((result as UrlTree).toString()).toBe(LOGIN_REDIRECT_FROM_HOME);
    expect(authService.isAuthenticated()).toBeFalse();
    expect(localStorage.getItem('auth_token')).toBeNull();
  });

  it('redirects to /login on network errors but keeps the token for a retry', async () => {
    localStorage.setItem('auth_token', STORED_TOKEN);
    injectAuthService();

    const pending = firstValueFrom(runGuard());
    httpMock.expectOne(SETTINGS_ENDPOINT).error(new ProgressEvent('network error'));

    const result = await pending;

    expect(result instanceof UrlTree).toBeTrue();
    expect((result as UrlTree).toString()).toBe(LOGIN_REDIRECT_FROM_HOME);
    expect(authService.isUnreachable()).toBeTrue();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);
  });

  it('redirects to /login without a request when no token exists', async () => {
    injectAuthService();

    const result = await firstValueFrom(runGuard());

    expect(result instanceof UrlTree).toBeTrue();
    expect((result as UrlTree).toString()).toBe(LOGIN_REDIRECT_FROM_HOME);
    expect(authService.isAuthenticated()).toBeFalse();
    httpMock.expectNone(SETTINGS_ENDPOINT);
  });

  it('allows further navigation without repeating the validation once authenticated', async () => {
    localStorage.setItem('auth_token', STORED_TOKEN);
    injectAuthService();

    const firstNavigation = firstValueFrom(runGuard());
    httpMock.expectOne(SETTINGS_ENDPOINT).flush({});
    expect(await firstNavigation).toBeTrue();

    const secondNavigation = await firstValueFrom(runGuard());

    expect(secondNavigation).toBeTrue();
    httpMock.expectNone(SETTINGS_ENDPOINT);
  });
});
