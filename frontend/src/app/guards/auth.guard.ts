import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { map } from 'rxjs';
import { AuthService } from '../services/auth.service';

export const authGuard: CanActivateFn = (route, state) => {
  const authService = inject(AuthService);
  const router = inject(Router);

  // Wartet bei 'checking' auf die laufende serverseitige Tokenprüfung, statt
  // geschützte UI vorzeitig zu zeigen oder unmittelbar zum Login umzuleiten.
  // 'unreachable' lässt die Weiterleitung zum Login zu; dort zeigt die Seite
  // den Prüfzustand mit erneuter Prüfung an, ohne das Token zu entfernen.
  // Das ursprüngliche Ziel bleibt als returnUrl erhalten.
  return authService.validateStoredToken().pipe(
    map(authenticated =>
      authenticated ||
      router.createUrlTree(['/login'], { queryParams: { returnUrl: state.url } })
    )
  );
};
