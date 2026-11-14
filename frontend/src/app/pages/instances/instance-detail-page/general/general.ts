import { ChangeDetectionStrategy, Component, DestroyRef, computed, effect, inject, signal } from '@angular/core';
import { FormBuilder, ReactiveFormsModule } from '@angular/forms';
import { ApiService } from '../../../../services/api-service';
import { takeUntilDestroyed, toSignal } from '@angular/core/rxjs-interop';
import { MatFormField, MatLabel } from '@angular/material/form-field';
import { MatInput } from '@angular/material/input';
import { MatSelect, MatOption } from '@angular/material/select';
import { TranslatePipe } from '@ngx-translate/core';
import { finalize } from 'rxjs/operators';
import { ButtonComponent } from '../../../../components/button/button';
import { NewInstanceStateService } from '../../new-instance/new-instance-state.service';
import { Instance, UpdateInstanceRequest } from '../../../../models/instance';

@Component({
  selector: 'app-new-instance-general',
  standalone: true,
  imports: [
    ReactiveFormsModule,
    MatFormField,
    MatInput,
    MatLabel,
    MatSelect,
    MatOption,
    TranslatePipe,
    ButtonComponent
  ],
  templateUrl: './general.html',
  styleUrls: ['./general.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class NewInstanceGeneralComponent {
  private readonly apiService = inject(ApiService);
  private readonly formBuilder = inject(FormBuilder);
  private readonly state = inject(NewInstanceStateService);
  private readonly destroyRef = inject(DestroyRef);

  public readonly isSubmitting = signal(false);
  public readonly statusMessage = signal<string | null>(null);
  public readonly statusType = signal<'success' | 'error' | null>(null);
  public readonly instance = computed(() => this.state.instance());
  public readonly instanceId = computed(() => this.state.instanceId());
  public readonly isLoadingInstance = computed(() => this.state.isInstanceLoading());
  public readonly hasInstance = computed(() => !this.isLoadingInstance() && this.instanceId() !== null);
  public readonly loaderVersion = computed(() => this.instance()?.modLoaderVersion ?? '');

  public readonly form = this.formBuilder.group({
    name: [''],
    description: [''],
    gameVersion: [{ value: '', disabled: true }],
    modLoader: [{ value: '', disabled: true }],
    loaderVersion: [{ value: '', disabled: true }],
    javaPath: ['']
  });

  // --- Data Signals ---
  public readonly javaVersions = toSignal(this.apiService.getJavaVersions());

  // Instance id the form was last patched from; a plain marker (not a signal)
  // so that the effect below does not re-trigger on its own bookkeeping.
  private lastPatchedInstanceId: string | null = null;

  constructor() {
    // Reflect the loaded instance in the form on first load and when the state
    // switches to another instance. A refresh for the same instance (for example
    // after a successful save) must not overwrite the form, because the user may
    // have edited fields while the save request was in flight.
    effect(() => {
      const instance = this.instance();
      if (!instance?.id || this.lastPatchedInstanceId === instance.id) {
        return;
      }
      this.patchFormFromInstance(instance);
      this.lastPatchedInstanceId = instance.id;
      // The save status of the previous instance must not leak into the one
      // the user just switched to.
      this.statusMessage.set(null);
      this.statusType.set(null);
    });

    // While another instance is being loaded the form still shows the previous
    // instance, so it must not accept input: edits would be dropped silently.
    effect(() => {
      this.setEditableFieldsEnabled(!this.isLoadingInstance());
    });
  }

  public saveChanges(): void {
    if (this.isSubmitting()) {
      return;
    }
    this.statusMessage.set(null);
    this.statusType.set(null);

    const instanceId = this.instanceId();
    if (!instanceId) {
      this.statusMessage.set('NEW_INSTANCE.INSTANCE_UNAVAILABLE');
      this.statusType.set('error');
      return;
    }

    const value = this.form.getRawValue();
    const name = (value.name ?? '').trim();
    if (!name) {
      this.statusMessage.set('NEW_INSTANCE.NAME_REQUIRED');
      this.statusType.set('error');
      return;
    }

    // The update endpoint replaces the whole instance config, so fields that are
    // not editable here (game version, loader, memory limits) must be carried over
    // from the currently loaded instance instead of being dropped.
    const current = this.instance();
    const request: UpdateInstanceRequest = {
      name,
      description: (value.description ?? '').trim() || undefined,
      gameVersion: current?.gameVersion,
      modLoader: current?.modLoader ? this.state.toBackendModLoader(current.modLoader) : undefined,
      modLoaderVersion: current?.modLoaderVersion,
      javaXmx: current?.javaXmx,
      javaXms: current?.javaXms,
      javaPath: (value.javaPath ?? '').trim() || undefined,
    };

    this.isSubmitting.set(true);
    this.apiService.updateInstance(instanceId, request).pipe(
      // A late response must not outlive the component or leak into the state
      // after the user switched to another instance while the request ran.
      takeUntilDestroyed(this.destroyRef),
      finalize(() => this.isSubmitting.set(false))
    ).subscribe({
      next: updated => {
        // The route reuses this component for another instance id; the state may
        // already hold that new instance while this stale response still arrives.
        if (this.instanceId() !== instanceId) {
          return;
        }
        this.state.setInstance(updated);
        this.statusMessage.set('NEW_INSTANCE.UPDATE_PROJECT_SUCCESS');
        this.statusType.set('success');
      },
      error: () => {
        // A late failure must not report a save error for an instance the user
        // has already navigated away from.
        if (this.instanceId() !== instanceId) {
          return;
        }
        this.statusMessage.set('NEW_INSTANCE.UPDATE_PROJECT_ERROR');
        this.statusType.set('error');
      }
    });
  }

  private setEditableFieldsEnabled(enabled: boolean): void {
    for (const name of ['name', 'description', 'javaPath'] as const) {
      const control = this.form.controls[name];
      if (enabled) {
        control.enable({ emitEvent: false });
      } else {
        control.disable({ emitEvent: false });
      }
    }
  }

  private patchFormFromInstance(instance: Instance): void {
    this.form.patchValue({
      name: instance.name ?? '',
      description: instance.description ?? '',
      gameVersion: instance.gameVersion ?? '',
      modLoader: instance.modLoader ?? '',
      loaderVersion: instance.modLoaderVersion ?? '',
      javaPath: instance.javaPath ?? ''
    }, { emitEvent: false });
  }
}
