import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ActivatedRoute, convertToParamMap, Router } from '@angular/router';
import { TranslateLoader, TranslateModule, TranslateService } from '@ngx-translate/core';
import { firstValueFrom, Observable, of, Subject } from 'rxjs';

import { authInterceptor } from '../../interceptors/auth.interceptor';
import { AuthService } from '../../services/auth.service';
import { ServerService } from '../../services/server-service';
import { LoginPage } from './login-page';

const BASE_ORIGIN = 'http://backend.test';
const SETTINGS_ENDPOINT = BASE_ORIGIN + '/api/v1/serverSettings';
const SETUP_STATUS_ENDPOINT = BASE_ORIGIN + '/api/v1/setup/status';
const LOGIN_ENDPOINT = BASE_ORIGIN + '/api/v1/auth/login';
const STORED_TOKEN = 'stored-session-token';

const authTranslations = {
  CHECKING: 'Checking your session …',
  BACKEND_UNREACHABLE:
    'The backend is currently unreachable, so your saved session could not be verified. Make sure the backend is running and try again.'
};

class LoginPageLoader extends TranslateLoader {
  getTranslation(_lang: string): Observable<any> {
    return of({ AUTH: authTranslations, RETRY: 'Try again' });
  }
}

describe('LoginPage', () => {
  let fixture: ComponentFixture<LoginPage>;
  let component: LoginPage;
  let authService: AuthService;
  let httpMock: HttpTestingController;
  let router: jasmine.SpyObj<Router>;
  const routeMock = { snapshot: { queryParamMap: convertToParamMap({}) } };

  beforeEach(async () => {
    localStorage.clear();
    routeMock.snapshot.queryParamMap = convertToParamMap({});
    router = jasmine.createSpyObj<Router>('Router', ['navigate']);

    TestBed.configureTestingModule({
      imports: [
        LoginPage,
        TranslateModule.forRoot({
          loader: { provide: TranslateLoader, useClass: LoginPageLoader }
        })
      ],
      providers: [
        { provide: Router, useValue: router },
        { provide: ActivatedRoute, useValue: routeMock },
        provideHttpClient(withInterceptors([authInterceptor])),
        provideHttpClientTesting(),
        { provide: ServerService, useValue: { getCurrentOrigin: () => BASE_ORIGIN } }
      ]
    });

    httpMock = TestBed.inject(HttpTestingController);
    await firstValueFrom(TestBed.inject(TranslateService).use('en'));
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  function createComponent(): void {
    authService = TestBed.inject(AuthService);
    fixture = TestBed.createComponent(LoginPage);
    component = fixture.componentInstance;
    fixture.detectChanges();
    httpMock.expectOne(SETUP_STATUS_ENDPOINT).flush({ setupRequired: false });
  }

  /**
   * Legt ein gespeichertes Token an und bringt den AuthService über eine
   * fehlgeschlagene Prüfung in den ehrlichen 'unreachable'-Zustand.
   */
  async function driveUnreachableSession(): Promise<void> {
    localStorage.setItem('auth_token', STORED_TOKEN);
    authService = TestBed.inject(AuthService);
    const validated = firstValueFrom(authService.validateStoredToken());
    httpMock.expectOne(SETTINGS_ENDPOINT).error(new ProgressEvent('network error'));
    expect(await validated).toBeFalse();
  }

  it('shows the plain login form without a stored token', () => {
    createComponent();

    expect(fixture.nativeElement.querySelector('.session-warning')).toBeNull();
    expect(fixture.nativeElement.querySelector('form')).not.toBeNull();
  });

  it('shows a safe unreachable notice with retry when the saved session could not be verified', async () => {
    await driveUnreachableSession();
    createComponent();
    await fixture.whenStable();
    fixture.detectChanges();

    const warning = fixture.nativeElement.querySelector('.session-warning');
    expect(warning).not.toBeNull();
    const warningText = warning.textContent;
    expect(warningText).toContain('backend is currently unreachable');
    expect(warningText).toContain('try again');
    expect(warningText).not.toContain(STORED_TOKEN);
    expect(warning.querySelector('button')).not.toBeNull();
  });

  it('retries the saved session without password entry and navigates home when it is valid', async () => {
    await driveUnreachableSession();
    createComponent();
    await fixture.whenStable();
    fixture.detectChanges();

    const retryButton = fixture.nativeElement.querySelector(
      '.session-warning button'
    ) as HTMLButtonElement;
    retryButton.click();

    const retryRequest = httpMock.expectOne(SETTINGS_ENDPOINT);
    expect(retryRequest.request.headers.get('Authorization')).toBe(`Bearer ${STORED_TOKEN}`);
    retryRequest.flush({});

    await fixture.whenStable();
    fixture.detectChanges();

    expect(router.navigate).toHaveBeenCalledWith(['/home']);
    expect(authService.isAuthenticated()).toBeTrue();
    expect(fixture.nativeElement.querySelector('.session-warning')).toBeNull();
  });

  it('keeps the notice when the retried check fails again', async () => {
    await driveUnreachableSession();
    createComponent();
    await fixture.whenStable();
    fixture.detectChanges();

    (fixture.nativeElement.querySelector('.session-warning button') as HTMLButtonElement).click();
    httpMock.expectOne(SETTINGS_ENDPOINT).error(new ProgressEvent('network error'));

    await fixture.whenStable();
    fixture.detectChanges();

    expect(router.navigate).not.toHaveBeenCalled();
    expect(authService.isUnreachable()).toBeTrue();
    expect(localStorage.getItem('auth_token')).toBe(STORED_TOKEN);
    expect(fixture.nativeElement.querySelector('.session-warning')).not.toBeNull();
  });

  it('navigates to the originally requested target after a successful retry', async () => {
    routeMock.snapshot.queryParamMap = convertToParamMap({ returnUrl: '/settings' });
    await driveUnreachableSession();
    createComponent();
    await fixture.whenStable();
    fixture.detectChanges();

    const retryButton = fixture.nativeElement.querySelector(
      '.session-warning button'
    ) as HTMLButtonElement;
    retryButton.click();

    const retryRequest = httpMock.expectOne(SETTINGS_ENDPOINT);
    retryRequest.flush({});

    await fixture.whenStable();
    fixture.detectChanges();

    expect(router.navigate).toHaveBeenCalledWith(['/settings']);
    expect(authService.isAuthenticated()).toBeTrue();
  });

  it('ignores repeated retry clicks while a check is running', async () => {
    await driveUnreachableSession();
    createComponent();
    await fixture.whenStable();
    fixture.detectChanges();

    const retryResult = new Subject<boolean>();
    spyOn(authService, 'validateStoredToken').and.returnValue(retryResult);

    const retryButton = fixture.nativeElement.querySelector(
      '.session-warning button'
    ) as HTMLButtonElement;
    retryButton.click();
    retryButton.click();

    expect(authService.validateStoredToken).toHaveBeenCalledTimes(1);

    retryResult.next(true);
    retryResult.complete();

    expect(router.navigate).toHaveBeenCalledTimes(1);
  });

  it('logs in with the password and navigates home on success', () => {
    createComponent();

    component.password = 'secret-password';
    component.login();

    const request = httpMock.expectOne(LOGIN_ENDPOINT);
    expect(request.request.method).toBe('POST');
    expect(request.request.body).toEqual({ password: 'secret-password' });
    request.flush({ token: 'issued-token' });

    expect(router.navigate).toHaveBeenCalledWith(['/home']);
    expect(authService.isAuthenticated()).toBeTrue();
  });

  it('navigates to the originally requested target after a successful password login', () => {
    // Der Passwort-Login honoriert denselben returnUrl-Vertrag wie die
    // Retry-Prüfung: nach der Anmeldung zum ursprünglichen Ziel zurückkehren.
    routeMock.snapshot.queryParamMap = convertToParamMap({ returnUrl: '/settings/themes' });
    createComponent();

    component.password = 'secret-password';
    component.login();

    httpMock.expectOne(LOGIN_ENDPOINT).flush({ token: 'issued-token' });

    expect(router.navigate).toHaveBeenCalledWith(['/settings/themes']);
    expect(authService.isAuthenticated()).toBeTrue();
  });

  it('redirects to setup when the backend reports pending setup', () => {
    fixture = TestBed.createComponent(LoginPage);
    fixture.detectChanges();
    httpMock.expectOne(SETUP_STATUS_ENDPOINT).flush({ setupRequired: true });

    expect(router.navigate).toHaveBeenCalledWith(['/setup']);
  });
});
