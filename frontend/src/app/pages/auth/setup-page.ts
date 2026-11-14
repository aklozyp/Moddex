import { Component, inject, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { AuthService } from '../../services/auth.service';
import { Router } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatStepperModule } from '@angular/material/stepper';
import { TranslatePipe } from '@ngx-translate/core';

const MIN_PASSWORD_LENGTH = 8;

type SetupError = {
  key: string;
  params?: Record<string, string | number>;
};

@Component({
  selector: 'app-setup-page',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatCardModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonModule,
    MatStepperModule,
    TranslatePipe
  ],
  templateUrl: './setup-page.html',
  styleUrl: './setup-page.scss'
})
export class SetupPage {
  private authService = inject(AuthService);
  private router = inject(Router);

  password = '';
  confirmPassword = '';
  bootstrapToken = '';
  error = signal<SetupError | null>(null);
  isLoading = signal(false);

  constructor() {
     // Verify if setup is actually needed
     this.authService.checkSetup().subscribe(status => {
       if (!status.setupRequired) {
         this.router.navigate(['/login']);
       }
     });
  }

  completeSetup() {
    this.error.set(null);

    if (this.password !== this.confirmPassword) {
      this.error.set({ key: 'SETUP.ERROR_PASSWORDS_DO_NOT_MATCH' });
      return;
    }
    if (this.password.length < MIN_PASSWORD_LENGTH) {
      this.error.set({
        key: 'SETUP.ERROR_PASSWORD_TOO_SHORT',
        params: { minLength: MIN_PASSWORD_LENGTH }
      });
      return;
    }

    this.isLoading.set(true);
    this.authService.completeSetup(this.password, this.bootstrapToken.trim()).subscribe({
      next: () => {
        this.isLoading.set(false);
        this.error.set(null);
        this.router.navigate(['/login']);
      },
      error: (error: unknown) => {
        this.isLoading.set(false);
        this.error.set(this.resolveSetupError(error));
      }
    });
  }

  private resolveSetupError(error: unknown): SetupError {
    if (error instanceof HttpErrorResponse) {
      const backendMessage = this.getBackendErrorMessage(error.error);

      if (error.status === 400 && backendMessage === 'Password must be at least 8 characters') {
        return {
          key: 'SETUP.ERROR_PASSWORD_TOO_SHORT',
          params: { minLength: MIN_PASSWORD_LENGTH }
        };
      }

      if (error.status === 409 && backendMessage === 'Setup already completed') {
        return { key: 'SETUP.ERROR_ALREADY_COMPLETED' };
      }

      if (error.status === 403) {
        return { key: 'SETUP.ERROR_BOOTSTRAP_PROOF' };
      }
    }

    return { key: 'SETUP.ERROR_GENERIC' };
  }

  private getBackendErrorMessage(body: unknown): string | null {
    if (typeof body === 'string') {
      return body.trim();
    }

    if (typeof body !== 'object' || body === null) {
      return null;
    }

    const response = body as { error?: unknown; message?: unknown };
    const message = typeof response.error === 'string' ? response.error : response.message;
    return typeof message === 'string' ? message.trim() : null;
  }
}
