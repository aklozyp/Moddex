import { inject } from '@angular/core';
import { CanDeactivateFn, RouterStateSnapshot } from '@angular/router';
import { TranslateService } from '@ngx-translate/core';
import { SettingsService } from '../services/settings-service';

function isNavigatingWithinSettings(nextState: RouterStateSnapshot | null): boolean {
  return !!nextState && nextState.url.startsWith('/settings');
}

export const pendingChangesGuard: CanDeactivateFn<unknown> = (
  _component,
  _currentRoute,
  _currentState,
  nextState
) => {
  const settingsService = inject(SettingsService);
  if (!settingsService.isDirty() || isNavigatingWithinSettings(nextState)) {
    return true;
  }

  const translate = inject(TranslateService);
  const message = translate.instant('UNSAVED_CHANGES_WARNING')
    || 'You have unsaved changes. Leave without saving?';

  const shouldLeave = window.confirm(message);
  if (shouldLeave) {
    settingsService.discard();
  }
  return shouldLeave;
};
