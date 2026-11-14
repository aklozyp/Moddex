import { HttpErrorResponse } from '@angular/common/http';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { Router } from '@angular/router';
import { TranslateLoader, TranslateModule, TranslateService } from '@ngx-translate/core';
import { firstValueFrom, Observable, of, throwError } from 'rxjs';

import { AuthService } from '../../services/auth.service';
import { SetupPage } from './setup-page';

const setupTranslations = {
  TITLE: 'Welcome to Moddex',
  SUBTITLE: 'Initial Setup',
  DESCRIPTION: 'Set an administrator password.',
  BOOTSTRAP_TOKEN_LABEL: 'Bootstrap Proof',
  BOOTSTRAP_TOKEN_HINT: 'One-time proof from setup-bootstrap-token.json on the server host.',
  PASSWORD_LABEL: 'Admin Password',
  CONFIRM_PASSWORD_LABEL: 'Confirm Password',
  COMPLETE_BUTTON: 'Complete Setup',
  ERROR_PASSWORDS_DO_NOT_MATCH: 'The passwords do not match. Enter the same password in both fields.',
  ERROR_PASSWORD_TOO_SHORT: 'Choose a password with at least {{minLength}} characters.',
  ERROR_BOOTSTRAP_PROOF: 'The bootstrap proof is missing, invalid, expired, or already used. Take the current proof from the setup file on the server host and try again.',
  ERROR_ALREADY_COMPLETED: 'Initial setup is already complete. Sign in instead.',
  ERROR_GENERIC: 'Setup could not be completed. Check your connection and try again.'
};

class SetupPageLoader extends TranslateLoader {
  getTranslation(_lang: string): Observable<any> {
    return of({ SETUP: setupTranslations });
  }
}

describe('SetupPage', () => {
  let component: SetupPage;
  let fixture: ComponentFixture<SetupPage>;
  let authService: jasmine.SpyObj<AuthService>;
  let router: jasmine.SpyObj<Router>;

  beforeEach(async () => {
    authService = jasmine.createSpyObj<AuthService>('AuthService', ['checkSetup', 'completeSetup']);
    authService.checkSetup.and.returnValue(of({ setupRequired: true }));
    authService.completeSetup.and.returnValue(of({}));
    router = jasmine.createSpyObj<Router>('Router', ['navigate']);

    await TestBed.configureTestingModule({
      imports: [
        SetupPage,
        TranslateModule.forRoot({
          loader: { provide: TranslateLoader, useClass: SetupPageLoader }
        })
      ],
      providers: [
        { provide: AuthService, useValue: authService },
        { provide: Router, useValue: router }
      ]
    }).compileComponents();

    await firstValueFrom(TestBed.inject(TranslateService).use('en'));
    fixture = TestBed.createComponent(SetupPage);
    component = fixture.componentInstance;
    component.bootstrapToken = 'test-bootstrap-proof';
    fixture.detectChanges();
  });

  it('uses translated text for password mismatch and minimum-length validation', () => {
    component.password = 'first-password';
    component.confirmPassword = 'different-password';
    component.completeSetup();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.error').textContent).toContain(
      'The passwords do not match'
    );
    expect(authService.completeSetup).not.toHaveBeenCalled();

    component.password = 'short';
    component.confirmPassword = 'short';
    component.completeSetup();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.error').textContent).toContain(
      'at least 8 characters'
    );
    expect(authService.completeSetup).not.toHaveBeenCalled();
  });

  it('maps the backend minimum-length error to its localized message', () => {
    authService.completeSetup.and.returnValue(
      throwError(
        () =>
          new HttpErrorResponse({
            status: 400,
            error: { error: 'Password must be at least 8 characters' }
          })
      )
    );
    component.password = 'long-enough-password';
    component.confirmPassword = component.password;

    component.completeSetup();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.error').textContent).toContain(
      'at least 8 characters'
    );
  });

  it('maps an already-completed backend setup error to a safe next action', () => {
    authService.completeSetup.and.returnValue(
      throwError(
        () =>
          new HttpErrorResponse({
            status: 409,
            error: { error: 'Setup already completed' }
          })
      )
    );
    component.password = 'long-enough-password';
    component.confirmPassword = component.password;

    component.completeSetup();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.error').textContent).toContain(
      'Sign in instead'
    );
  });

  it('maps a rejected bootstrap proof to a safe next action without echoing backend details', () => {
    const backendMessage = 'Setup requires the current one-time bootstrap proof from the file setup-bootstrap-token.json';
    authService.completeSetup.and.returnValue(
      throwError(
        () =>
          new HttpErrorResponse({
            status: 403,
            error: { error: backendMessage }
          })
      )
    );
    component.password = 'long-enough-password';
    component.confirmPassword = component.password;

    component.completeSetup();
    fixture.detectChanges();

    const displayedError = fixture.nativeElement.querySelector('.error').textContent;
    expect(displayedError).toContain('bootstrap proof');
    expect(displayedError).toContain('try again');
  });

  it('sends the entered bootstrap proof and keeps the submit button disabled without it', () => {
    component.password = 'long-enough-password';
    component.confirmPassword = component.password;

    component.completeSetup();

    expect(authService.completeSetup).toHaveBeenCalledWith(
      'long-enough-password',
      'test-bootstrap-proof'
    );

    component.bootstrapToken = '  ';
    fixture.detectChanges();
    const button: HTMLButtonElement = fixture.nativeElement.querySelector('button');
    expect(button.disabled).toBeTrue();

    component.bootstrapToken = 'fresh-proof-from-server';
    fixture.detectChanges();
    expect(button.disabled).toBeFalse();
  });

  it('uses a safe translated fallback without exposing unknown backend details', () => {
    const rawBackendError = 'private password, token, and provider-key details';
    authService.completeSetup.and.returnValue(
      throwError(
        () =>
          new HttpErrorResponse({
            status: 500,
            error: { error: rawBackendError }
          })
      )
    );
    component.password = 'long-enough-password';
    component.confirmPassword = component.password;

    component.completeSetup();
    fixture.detectChanges();

    const displayedError = fixture.nativeElement.querySelector('.error').textContent;
    expect(displayedError).toContain('Check your connection and try again');
    expect(displayedError).not.toContain(rawBackendError);
    expect(displayedError).not.toContain('password');
    expect(displayedError).not.toContain('token');
    expect(displayedError).not.toContain('provider-key');
  });

  it('completes setup and navigates to login on success', () => {
    component.password = 'long-enough-password';
    component.confirmPassword = component.password;

    component.completeSetup();

    expect(authService.completeSetup).toHaveBeenCalledWith('long-enough-password', 'test-bootstrap-proof');
    expect(component.isLoading()).toBeFalse();
    expect(router.navigate).toHaveBeenCalledWith(['/login']);
  });
});
