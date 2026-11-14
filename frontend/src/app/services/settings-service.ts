import { computed, effect, inject, Injectable, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { catchError, firstValueFrom, of } from 'rxjs';
import { ServerService } from './server-service';
import { ThemeService } from './theme-service';
import { ClientSettings } from '../models/client-settings';

const LS_SETTINGS = 'moddex.settings';

// Simple deep equal function for comparing settings objects
function isEqual(a: any, b: any): boolean {
  if (a === b) return true;
  if (a === null || a === undefined || b === null || b === undefined) return false;
  if (typeof a !== 'object' || typeof b !== 'object') return false;

  const keysA = Object.keys(a);
  const keysB = Object.keys(b);

  if (keysA.length !== keysB.length) return false;

  for (const key of keysA) {
    if (!keysB.includes(key) || !isEqual(a[key], b[key])) {
      return false;
    }
  }
  return true;
}

function deepClone<T>(value: T): T {
  if (value === null || value === undefined) {
    return value;
  }
  return JSON.parse(JSON.stringify(value));
}

@Injectable({
  providedIn: 'root'
})
export class SettingsService {
  private http = inject(HttpClient);
  private serverService = inject(ServerService);
  private themeService = inject(ThemeService);

  private settings = signal<ClientSettings | null>(null);
  private draftSettings = signal<ClientSettings | null>(null);

  public isDirty = computed(() => {
    const original = this.settings();
    const draft = this.draftSettings();
    if (!original || !draft) return false;
    return !isEqual(original, draft);
  });

  public settings$ = this.settings.asReadonly();
  public draftSettings$ = this.draftSettings.asReadonly();

  constructor() {
    // When the draft settings change, apply them to the relevant services
    effect(() => {
      const draft = this.draftSettings();
      if (draft) {
        this.themeService.set(draft.webTheme);
      }
    });
  }

  async loadInitialSettings() {
    const currentOrigin = this.serverService.getCurrentOrigin();

    let loadedSettings = await this.fetchSettingsFromServer(currentOrigin);

    if (!loadedSettings) {
      loadedSettings = this.loadFromLocalStorage();
    }

    if (!loadedSettings) {
      loadedSettings = { webTheme: 'dark' };
    }

    const snapshot = deepClone(loadedSettings);
    this.settings.set(snapshot);
    this.draftSettings.set(deepClone(snapshot));
    this.saveToLocalStorage(snapshot);
  }

  private async fetchSettingsFromServer(serverUrl: string): Promise<ClientSettings | null> {
    return firstValueFrom(
      this.http.get<ClientSettings>(`${serverUrl}/api/client/settings`).pipe(
        catchError(() => of(null))
      )
    );
  }

  private loadFromLocalStorage(): ClientSettings | null {
    try {
      const raw = localStorage.getItem(LS_SETTINGS);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed.webTheme !== 'string') return null;
      return parsed as ClientSettings;
    } catch {
      return null;
    }
  }

  private saveToLocalStorage(settings: ClientSettings) {
    try {
      localStorage.setItem(LS_SETTINGS, JSON.stringify(settings));
    } catch (e) {
      console.error('Error saving settings to localStorage', e);
    }
  }

  updateDraft(draft: Partial<ClientSettings>) {
    this.draftSettings.update(current => ({ ...current, ...draft } as ClientSettings));
  }

  async save() {
    const draft = this.draftSettings();
    if (!draft || !this.isDirty()) return;

    const payload = deepClone(draft);
    const baseUrl = this.serverService.getCurrentOrigin();

    let saved: ClientSettings | null = null;
    try {
      saved = await firstValueFrom(
        this.http.post<ClientSettings>(`${baseUrl}/api/client/settings`, payload).pipe(
          catchError((error) => {
            console.error('Failed to save settings to server', error);
            return of(null);
          })
        )
      );
    } catch (error) {
      console.error('Failed to save settings to server', error);
    }

    const snapshot = deepClone(saved ?? payload);
    this.settings.set(snapshot);
    this.draftSettings.set(deepClone(snapshot));
    this.saveToLocalStorage(snapshot);
  }

  discard() {
    const original = this.settings();
    if (original) {
      this.draftSettings.set(deepClone(original));
    }
  }
}
