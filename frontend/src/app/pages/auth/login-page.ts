import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { AuthService } from '../../services/auth.service';
import { ActivatedRoute, Router } from '@angular/router';
import { TranslateModule } from '@ngx-translate/core';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';

@Component({
  selector: 'app-login-page',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    TranslateModule,
    MatCardModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonModule
  ],
  templateUrl: './login-page.html',
  styleUrl: './login-page.scss'
})
export class LoginPage {
  private authService = inject(AuthService);
  private router = inject(Router);
  private route = inject(ActivatedRoute);

  protected readonly isUnreachable = this.authService.isUnreachable;

  /** Ursprünglich angefordertes Ziel; nach erfolgreicher Retry-Prüfung wieder aufsuchen. */
  private readonly returnUrl = this.resolveReturnUrl();

  password = '';
  error = signal<string | null>(null);
  isLoading = signal(false);
  isRetryingSessionCheck = signal(false);

  constructor() {
    // Check if setup is required
    this.authService.checkSetup().subscribe(status => {
      if (status.setupRequired) {
        this.router.navigate(['/setup']);
      }
    });
  }

  login() {
    if (!this.password) return;

    this.isLoading.set(true);
    this.error.set(null);

    this.authService.login(this.password).subscribe({
      next: () => {
        this.isLoading.set(false);
        // Derselbe Rückkehr-Vertrag wie bei retrySessionCheck: nach dem Login
        // zum ursprünglich angeforderten Ziel (Fallback /home) zurückkehren.
        this.router.navigate([this.returnUrl]);
      },
      error: () => {
        this.isLoading.set(false);
        this.error.set('Invalid Password');
      }
    });
  }

  /**
   * Wiederholt die serverseitige Prüfung des gespeicherten Tokens, ohne den
   * Nutzer zur Neueingabe des Passworts zu zwingen. Nur bei nachgewiesener
   * Gültigkeit geht es zum ursprünglich angeforderten Ziel (Fallback /home);
   * das Token bleibt bei Fehlern erhalten.
   */
  retrySessionCheck() {
    if (this.isRetryingSessionCheck()) return;

    this.isRetryingSessionCheck.set(true);
    this.authService.validateStoredToken().subscribe(valid => {
      this.isRetryingSessionCheck.set(false);
      if (valid) {
        this.router.navigate([this.returnUrl]);
      }
    });
  }

  /**
   * Akzeptiert nur interne Pfade als Rückkehrziel; alles andere (etwa ein von
   * außen gesetzter Fremd-URL-Parameter) fällt auf /home zurück.
   */
  private resolveReturnUrl(): string {
    const requested = this.route.snapshot.queryParamMap.get('returnUrl');
    return requested && requested.startsWith('/') && !requested.startsWith('//')
      ? requested
      : '/home';
  }
}
