import { computed, inject, Injectable, signal } from '@angular/core';
import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { Router } from '@angular/router';
import { firstValueFrom, from, Observable, of, tap, timeout } from 'rxjs';
import { ServerService } from './server-service';

/**
 * Zustand der Anmeldung:
 * - 'checking': ein gespeichertes Token wird serverseitig geprüft.
 * - 'authenticated': das Token wurde vom Backend als gültig bestätigt.
 * - 'unauthenticated': kein Token vorhanden oder das Backend hat es verworfen (401/403).
 * - 'unreachable': die Prüfung ist am Backend gescheitert (Netzwerk-/Serverfehler);
 *   das Token bleibt erhalten, damit der Nutzer nicht vorschnell abgemeldet wird.
 */
export type AuthState = 'checking' | 'authenticated' | 'unauthenticated' | 'unreachable';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private http = inject(HttpClient);
  private router = inject(Router);
  private serverService = inject(ServerService);

  private readonly authState = signal<AuthState>(
    localStorage.getItem('auth_token') ? 'checking' : 'unauthenticated'
  );
  private validation: Promise<boolean> | null = null;

  /** Begrenzt die Startprüfung, damit eine hängende Backend-Verbindung die App nicht blockiert. */
  private readonly validationTimeoutMs = 10_000;

  readonly isAuthenticated = computed(() => this.authState() === 'authenticated');
  readonly isChecking = computed(() => this.authState() === 'checking');
  readonly isUnreachable = computed(() => this.authState() === 'unreachable');

  login(password: string): Observable<any> {
    const base = this.serverService.getCurrentOrigin();
    return this.http.post<any>(`${base}/api/v1/auth/login`, { password }).pipe(
      tap(response => {
        if (response.token) {
          localStorage.setItem('auth_token', response.token);
          this.authState.set('authenticated');
        }
      })
    );
  }

  logout() {
    localStorage.removeItem('auth_token');
    this.authState.set('unauthenticated');
    this.router.navigate(['/login']);
  }

  /**
   * Prüft ein gespeichertes Token serverseitig über den leichten
   * authentifizierten GET-Endpunkt /api/v1/serverSettings. Läuft bereits eine
   * Prüfung, warten alle Aufrufer auf dasselbe Ergebnis (genau ein Request).
   * Liefert ausschließlich true bei nachgewiesener Gültigkeit; bei 401/403
   * wird das Token entfernt, bei anderen Fehlern (z. B. Backend offline)
   * bleibt es erhalten. Das Token selbst wird dabei nie ausgegeben.
   */
  validateStoredToken(): Observable<boolean> {
    const state = this.authState();
    if (state === 'authenticated') {
      return of(true);
    }
    if (state === 'unauthenticated') {
      return of(false);
    }
    if (!this.validation) {
      this.validation = this.performValidation().finally(() => {
        this.validation = null;
      });
    }
    return from(this.validation);
  }

  private async performValidation(): Promise<boolean> {
    this.authState.set('checking');
    try {
      await firstValueFrom(
        this.http
          .get(`${this.serverService.getCurrentOrigin()}/api/v1/serverSettings`)
          .pipe(
            // Hängt das Backend, darf die Navigation nicht ewig offen bleiben;
            // der Timeout zählt wie jeder andere Transportfehler, nie als 401/403.
            timeout(this.validationTimeoutMs)
          )
      );
      if (this.authState() === 'unauthenticated') {
        // Ein inzwischen erfolgter Logout darf nicht überschrieben werden.
        return false;
      }
      this.authState.set('authenticated');
      return true;
    } catch (error) {
      if (this.authState() === 'unauthenticated') {
        // Ein inzwischen erfolgter Logout darf nicht durch einen
        // Prüfungsfehler auf 'unreachable' überschrieben werden.
        return false;
      }
      if (this.authState() === 'authenticated') {
        // Eine inzwischen erfolgreiche Anmeldung darf nicht überschrieben werden.
        return true;
      }
      if (error instanceof HttpErrorResponse && (error.status === 401 || error.status === 403)) {
        localStorage.removeItem('auth_token');
        this.authState.set('unauthenticated');
      } else {
        // Transportfehler (z. B. TimeoutError) und Serverstörungen: Token
        // behalten und den ehrlichen Prüfzustand mit Retry-Möglichkeit zeigen.
        this.authState.set('unreachable');
      }
      return false;
    }
  }

  checkSetup(): Observable<{ setupRequired: boolean }> {
    const base = this.serverService.getCurrentOrigin();
    return this.http.get<{ setupRequired: boolean }>(`${base}/api/v1/setup/status`);
  }

  completeSetup(password: string, bootstrapToken: string): Observable<any> {
    const base = this.serverService.getCurrentOrigin();
    return this.http.post(`${base}/api/v1/setup/complete`, { password, bootstrapToken });
  }
}
