import { ChangeDetectionStrategy, Component, computed, effect, inject, signal } from '@angular/core';
import { TranslatePipe } from '@ngx-translate/core';
import { MatFormField } from '@angular/material/form-field';
import { MatSelect, MatOption } from '@angular/material/select';
import { MatSlideToggle } from '@angular/material/slide-toggle';
import { ButtonComponent } from '../../../../components/button/button';
import { SaveBarComponent } from '../../../../components/save-bar/save-bar';
import { NewInstanceStateService } from '../../new-instance/new-instance-state.service';
import { ApiService } from '../../../../services/api-service';
import { ServerPropertiesDto, ServerPropertyEntry } from '../../../../models/server-properties';
import { finalize } from 'rxjs/operators';
import { MatIconModule } from '@angular/material/icon';

@Component({
  selector: 'app-new-instance-advanced',
  standalone: true,
  imports: [
    TranslatePipe,
    MatFormField,
    MatSelect,
    MatOption,
    MatSlideToggle,
    MatIconModule,
    ButtonComponent,
    SaveBarComponent
  ],
  templateUrl: './advanced.html',
  styleUrls: ['./advanced.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NewInstanceAdvancedComponent {
  private readonly state = inject(NewInstanceStateService);
  private readonly api = inject(ApiService);

  public readonly projectCreated = computed(() => this.state.isProjectCreated());
  public readonly serverProperties = computed(() => this.state.serverProperties());
  public readonly propertyStats = computed(() => {
    const dto = this.serverProperties();
    if (!dto) {
      return { categories: 0, total: 0, toggles: 0, changed: 0 };
    }
    let total = 0;
    let toggles = 0;
    let changed = 0;
    for (const category of dto.categories) {
      total += category.entries.length;
      for (const entry of category.entries) {
        if (entry.type === 'BOOLEAN') {
          toggles += 1;
        }
        if (entry.hasChanged) {
          changed += 1;
        }
      }
    }
    return {
      categories: dto.categories.length,
      total,
      toggles,
      changed,
    };
  });

  private readonly draftValues = signal<Record<string, unknown>>({});
  private readonly editingKey = signal<string | null>(null);
  public readonly isSaving = signal(false);
  public readonly isResetting = signal(false);
  public readonly successMessage = signal<string | null>(null);
  public readonly errorMessage = signal<string | null>(null);

  public readonly hasChanges = computed(() => Object.keys(this.draftValues()).length > 0);
  public readonly pendingDraftCount = computed(() => Object.keys(this.draftValues()).length);

  private readonly _resetEffect = effect(() => {
    const properties = this.serverProperties();
    if (properties) {
      this.draftValues.set({});
      this.editingKey.set(null);
    }
  });

  public startEditing(key: string): void {
    this.editingKey.set(key);
  }

  public stopEditing(key: string): void {
    if (this.editingKey() === key) {
      this.editingKey.set(null);
    }
  }

  public isEditing(entry: ServerPropertyEntry): boolean {
    return this.editingKey() === entry.key;
  }

  public isStringLike(entry: ServerPropertyEntry): boolean {
    return entry.type === 'STRING' || entry.type === 'INTEGER';
  }

  public booleanValue(entry: ServerPropertyEntry): boolean {
    return Boolean(this.currentValue(entry));
  }

  public stringValue(entry: ServerPropertyEntry): string {
    const value = this.currentValue(entry);
    if (value === null || value === undefined) {
      return '';
    }
    return String(value);
  }

  public currentValue(entry: ServerPropertyEntry): string | number | boolean | null {
    const draft = this.draftValues()[entry.key];
    if (draft !== undefined) {
      return draft as string | number | boolean | null;
    }
    switch (entry.type) {
      case 'BOOLEAN':
        return entry.value ?? false;
      case 'INTEGER':
        return entry.value ?? 0;
      default:
        return (entry.value ?? '') as string;
    }
  }

  public isEmpty(entry: ServerPropertyEntry): boolean {
    if (entry.type === 'BOOLEAN') {
      return false;
    }
    const value = this.currentValue(entry);
    return value === null || value === undefined || value === '';
  }

  public hasDefault(entry: ServerPropertyEntry): boolean {
    return entry.defaultValue !== undefined && entry.defaultValue !== null && entry.defaultValue !== '';
  }

  public hasServerSideChange(entry: ServerPropertyEntry): boolean {
    return entry.hasChanged === true;
  }

  public handleBooleanChange(entry: ServerPropertyEntry, value: boolean): void {
    this.applyDraft(entry, value);
  }

  public handleEnumChange(entry: ServerPropertyEntry, value: string): void {
    this.applyDraft(entry, value);
  }

  public onTextInput(entry: ServerPropertyEntry, event: Event): void {
    const target = event.target as HTMLInputElement | null;
    if (!target) {
      return;
    }
    const raw = target.value;
    if (entry.type === 'INTEGER') {
      if (raw === '') {
        this.applyDraft(entry, null);
        return;
      }
      const numeric = Number(raw);
      if (!Number.isFinite(numeric)) {
        return;
      }
      this.applyDraft(entry, numeric);
      return;
    }
    this.applyDraft(entry, raw);
  }

  public saveChanges(): void {
    if (!this.hasChanges() || this.isSaving()) {
      return;
    }
    const instanceId = this.state.instanceId();
    if (!instanceId) {
      return;
    }

    const payload = { ...this.draftValues() };
    this.isSaving.set(true);
    this.successMessage.set(null);
    this.errorMessage.set(null);

    this.api.updateServerProperties(instanceId, { values: payload }).pipe(
      finalize(() => this.isSaving.set(false))
    ).subscribe({
      next: (dto: ServerPropertiesDto) => {
        this.state.updateServerProperties(dto);
        this.draftValues.set({});
        this.successMessage.set('SERVER_PROPERTIES.SAVE_SUCCESS');
      },
      error: () => {
        this.errorMessage.set('SERVER_PROPERTIES.SAVE_ERROR');
      }
    });
  }

  public discardChanges(): void {
    if (!this.hasChanges()) {
      return;
    }
    this.draftValues.set({});
    this.editingKey.set(null);
    this.successMessage.set(null);
    this.errorMessage.set(null);
  }

  public resetToOriginal(): void {
    if (this.isResetting()) {
      return;
    }
    const instanceId = this.state.instanceId();
    if (!instanceId) {
      return;
    }

    this.isResetting.set(true);
    this.successMessage.set(null);
    this.errorMessage.set(null);

    this.api.resetServerProperties(instanceId).pipe(
      finalize(() => this.isResetting.set(false))
    ).subscribe({
      next: (dto: ServerPropertiesDto) => {
        this.state.updateServerProperties(dto);
        this.draftValues.set({});
        this.successMessage.set('SERVER_PROPERTIES.RESET_SUCCESS');
      },
      error: () => {
        this.errorMessage.set('SERVER_PROPERTIES.RESET_ERROR');
      }
    });
  }

  public isChanged(entry: ServerPropertyEntry): boolean {
    return this.draftValues()[entry.key] !== undefined;
  }

  private applyDraft(entry: ServerPropertyEntry, rawValue: unknown): void {
    const normalized = this.normalizeValue(entry, rawValue);
    const original = this.normalizeValue(entry, entry.value);

    this.draftValues.update(current => {
      const updated = { ...current };
      if (this.valuesEqual(entry.type, original, normalized)) {
        delete updated[entry.key];
      } else {
        updated[entry.key] = normalized;
      }
      return updated;
    });
  }

  private normalizeValue(entry: ServerPropertyEntry, value: unknown): unknown {
    if (value === null || value === undefined) {
      return entry.type === 'BOOLEAN' ? false : value;
    }

    switch (entry.type) {
      case 'BOOLEAN':
        return Boolean(value);
      case 'INTEGER':
        return Number(value);
      default:
        return String(value);
    }
  }

  private valuesEqual(type: ServerPropertyEntry['type'], a: unknown, b: unknown): boolean {
    switch (type) {
      case 'BOOLEAN':
        return Boolean(a) === Boolean(b);
      case 'INTEGER':
        return Number(a ?? Number.NaN) === Number(b ?? Number.NaN);
      default:
        return String(a ?? '') === String(b ?? '');
    }
  }
}
