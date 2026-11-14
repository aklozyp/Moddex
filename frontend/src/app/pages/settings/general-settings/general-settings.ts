import { Component, computed, inject, signal } from '@angular/core';
import { TranslatePipe, TranslateService } from '@ngx-translate/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';
import { ApiService } from '../../../services/api-service';
import { ServerSettings } from '../../../models/server-settings';
import { ModDataProvider } from '../../../models/mod-data-provider';

@Component({
  selector: 'app-general-settings',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatFormFieldModule,
    MatInputModule,
    MatSelectModule,
    MatButtonModule,
    MatIconModule,
    MatSnackBarModule,
    TranslatePipe,
  ],
  templateUrl: './general-settings.html',
  styleUrl: './general-settings.scss'
})
export class GeneralSettingsComponent {
  private readonly api = inject(ApiService);
  private readonly snackBar = inject(MatSnackBar);
  private readonly translate = inject(TranslateService);

  readonly currentServer = window.location.origin;

  readonly serverSettings = signal<ServerSettings | null>(null);
  readonly draft = signal<ServerSettings | null>(null);
  readonly isLoading = signal(true);
  readonly isSaving = signal(false);
  readonly error = signal<string | null>(null);

  readonly isDirty = computed(() => {
    const original = this.serverSettings();
    const draft = this.draft();
    if (!original || !draft) {
      return false;
    }
    return JSON.stringify(original) !== JSON.stringify(draft);
  });

  readonly canSave = computed(() => {
    const draft = this.draft();
    if (!draft) {
      return false;
    }
    if (draft.modProvider === 'CURSEFORGE') {
      return Boolean(draft.curseForgeApiKey && draft.curseForgeApiKey.trim().length > 0);
    }
    return true;
  });

  readonly providers: { value: ModDataProvider; label: string }[] = [
    { value: 'MODRINTH', label: 'Modrinth' },
    { value: 'CURSEFORGE', label: 'CurseForge' },
  ];

  constructor() {
    this.loadSettings();
  }

  updateDraft(partial: Partial<ServerSettings>): void {
    this.draft.update(current => ({
      ...(current ?? { modProvider: 'MODRINTH' }),
      ...partial,
    }));
  }

  save(): void {
    const draft = this.draft();
    if (!draft || !this.isDirty() || this.isSaving()) {
      return;
    }

    this.isSaving.set(true);
    const payload: ServerSettings = {
      ...draft,
      modProvider: draft.modProvider ?? 'MODRINTH',
      curseForgeApiKey: draft.curseForgeApiKey?.trim() || undefined,
    };

    this.api.updateServerSettings(payload)
      .subscribe({
        next: updated => {
          const snapshot = clone(updated);
          this.serverSettings.set(snapshot);
          this.draft.set(clone(snapshot));
          this.isSaving.set(false);
          this.snackBar.open(this.translate.instant('GENERAL_SETTINGS.SAVE_SUCCESS'), undefined, { duration: 3000 });
        },
        error: error => {
          console.error('Failed to save server settings', error);
          this.snackBar.open(this.translate.instant('GENERAL_SETTINGS.SAVE_ERROR'), undefined, { duration: 4000 });
          this.isSaving.set(false);
        }
      });
  }

  reset(): void {
    const original = this.serverSettings();
    if (!original) {
      return;
    }
    this.draft.set(clone(original));
  }

  reload(): void {
    if (this.isLoading()) {
      return;
    }
    this.loadSettings();
  }

  private loadSettings(): void {
    this.isLoading.set(true);
    this.api.getServerSettings().subscribe({
      next: settings => {
        const snapshot = clone({
          ...settings,
          modProvider: settings.modProvider ?? 'MODRINTH',
        });
        this.serverSettings.set(snapshot);
        this.draft.set(clone(snapshot));
        this.error.set(null);
        this.isLoading.set(false);
      },
      error: error => {
        console.error('Failed to load server settings', error);
        this.error.set(this.translate.instant('GENERAL_SETTINGS.LOAD_ERROR'));
        this.isLoading.set(false);
      }
    });
  }
}

function clone<T>(value: T): T {
  return value ? JSON.parse(JSON.stringify(value)) : value;
}
