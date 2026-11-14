import {ChangeDetectionStrategy, Component, DestroyRef, computed, effect, inject, signal} from '@angular/core';
import { Router, RouterModule } from '@angular/router';
import { NewInstanceStateService } from './new-instance-state.service';
import {ButtonComponent} from '../../../components/button/button';
import {MatCheckbox} from '@angular/material/checkbox';
import {ErrorStateMatcher} from '@angular/material/core';
import {MatInput, MatLabel} from '@angular/material/input';
import {AbstractControl, FormBuilder, ReactiveFormsModule, ValidationErrors, Validators} from '@angular/forms';
import {MatError} from '@angular/material/form-field';
import {TranslatePipe} from '@ngx-translate/core';
import {ApiService} from '../../../services/api-service';
import {takeUntilDestroyed, toSignal} from '@angular/core/rxjs-interop';
import {CompatibleLoader} from '../../../models/compatible-loader';
import {CreateInstanceRequest, ModLoader} from '../../../models/instance';
import {catchError, map, of, startWith, switchMap, tap} from 'rxjs';
import {finalize} from 'rxjs/operators';
import {MatFormField} from '@angular/material/form-field';
import {MatOptgroup, MatOption, MatSelect} from '@angular/material/select';

/**
 * The backend creation flow only accepts a name it can build an instance
 * directory from: a blank name would silently fall through to the server's
 * "unnamed" fallback, which the sibling instance settings already prevent by
 * trimming and rejecting empty names. Whitespace-only input therefore counts
 * as empty, and the error key matches the built-in required validator so the
 * field renders a single shared message.
 */
function nonBlank(control: AbstractControl): ValidationErrors | null {
  const value = control.value;
  return typeof value === 'string' && value.trim().length > 0 ? null : { required: true };
}

/**
 * The backend requires a loader version for every non-vanilla loader (HTTP 400
 * "modLoaderVersion is required ...") and treats a missing loader as vanilla,
 * which needs none. This mirrors that contract for the form control.
 */
function requiresLoaderVersion(loader: string | null | undefined): boolean {
  const normalized = loader?.trim().toLowerCase();
  return !!normalized && normalized !== 'vanilla';
}

/**
 * The compatible loader list always belongs to exactly one selected Minecraft
 * version: switching the version cancels the still-pending request of the
 * previous selection, so a slow stale response can never overwrite the list
 * of the current selection. Every switch starts from a defined phase instead
 * of showing the previous version's loaders while the next request is in
 * flight, and a failed fetch surfaces as a retryable error state rather than
 * a silent empty list.
 */
type CompatibleLoadersState =
  | { phase: 'idle' }
  | { phase: 'loading' }
  | { phase: 'loaded'; data: CompatibleLoader[] }
  | { phase: 'failed' };

/**
 * The create button stays disabled until the form is valid, so the form is
 * never submitted while invalid and Material's default matcher (errors after
 * the field was touched) would never reveal why creation is locked. Errors
 * therefore show as soon as the field is invalid, keeping the locked submit
 * explainable for keyboard and screen-reader users.
 */
class InvalidFieldErrorStateMatcher implements ErrorStateMatcher {
  isErrorState(control: AbstractControl | null): boolean {
    return !!control && control.invalid;
  }
}

@Component({
  selector: 'app-new-instance',
  standalone: true,
  imports: [RouterModule, ButtonComponent, MatCheckbox, MatError, MatFormField, MatInput, MatLabel, MatOptgroup, MatOption, MatSelect, ReactiveFormsModule, TranslatePipe],
  templateUrl: './new-instance.html',
  styleUrl: './new-instance.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [{ provide: ErrorStateMatcher, useClass: InvalidFieldErrorStateMatcher }],
})
export class NewInstance {
  private readonly apiService = inject(ApiService);
  private readonly formBuilder = inject(FormBuilder);
  private readonly state = inject(NewInstanceStateService);
  private readonly router = inject(Router);
  private readonly destroyRef = inject(DestroyRef);

  public readonly isSubmitting = signal(false);
  public readonly statusMessage = signal<string | null>(null);
  public readonly statusType = signal<'success' | 'error' | null>(null);
  public readonly projectCreated = this.state.isProjectCreated;

  public readonly form = this.formBuilder.group({
    name: ['', nonBlank],
    description: [''],
    // The backend rejects a create request without a game version with
    // HTTP 400, so the assistant may not submit until one is chosen.
    minecraftVersion: ['', Validators.required],
    modLoader: [''],
    loaderVersion: [''],
    showOnlyReleases: [true]
  });

  // --- Submit gate ---
  // The disabled submit state must be signal-driven: validity changes alone do
  // not run change detection in this OnPush component, and statusChanges is
  // emitted on every recalculation, so toSignal keeps the gate current.
  private readonly formStatus = toSignal(this.form.statusChanges, { initialValue: this.form.status });
  public readonly canSubmit = computed(() => this.formStatus() === 'VALID' && !this.isSubmitting() && !this.projectCreated());

  // --- Input Signals ---
  private readonly showOnlyReleases = toSignal(this.form.controls.showOnlyReleases.valueChanges, { initialValue: true });
  public readonly minecraftVersion = toSignal(this.form.controls.minecraftVersion.valueChanges, { initialValue: '' });
  public readonly modLoader = toSignal(this.form.controls.modLoader.valueChanges, { initialValue: '' });

  // --- Data Signals ---
  private readonly minecraftVersions = toSignal(this.apiService.getMinecraftVersions());

  // The loader fetch follows the Minecraft version changes: switchMap cancels
  // the request of a previous selection as soon as the version changes, so
  // only the response of the currently selected version is ever applied. The
  // reset of the loader choice is part of the same stream, because its
  // previous value belongs to the previous version; resetting it also clears
  // the loader version together with its requirement (effect below).
  private readonly compatibleLoadersState = toSignal(
    this.form.controls.minecraftVersion.valueChanges.pipe(
      tap(() => this.form.controls.modLoader.setValue('')),
      switchMap(mcVersion => {
        if (!mcVersion) {
          return of<CompatibleLoadersState>({ phase: 'idle' });
        }
        return this.apiService.getCompatibleLoaders(mcVersion).pipe(
          map((data): CompatibleLoadersState => ({ phase: 'loaded', data })),
          startWith<CompatibleLoadersState>({ phase: 'loading' }),
          catchError(() => of<CompatibleLoadersState>({ phase: 'failed' })),
        );
      }),
    ),
    { initialValue: { phase: 'idle' } },
  );

  // --- Computed Signals for UI ---
  public readonly filteredMinecraftVersions = computed(() => {
    if (this.showOnlyReleases()) {
      const regex = /^\d+\.\d+(\.\d+)?$/;
      return this.minecraftVersions()?.filter(version => regex.test(version));
    }
    return this.minecraftVersions();
  });

  public readonly groupedMinecraftVersions = computed(() => {
    const versions = this.filteredMinecraftVersions();
    if (!versions) return null;
    const grouped = new Map<string, string[]>();
    for (const version of versions) {
      const majorVersion = version.split('.').slice(0, 2).join('.');
      if (!grouped.has(majorVersion)) {
        grouped.set(majorVersion, []);
      }
      grouped.get(majorVersion)!.push(version);
    }
    return grouped;
  });

  public readonly modLoaders = computed(() => {
    const state = this.compatibleLoadersState();
    const loaders = state.phase === 'loaded' ? state.data.map(data => data.loader) : [];
    const capitalizedLoaders = loaders.map(l => l.charAt(0).toUpperCase() + l.slice(1));
    return ['Vanilla', ...capitalizedLoaders];
  });

  public readonly loaderVersions = computed(() => {
    const state = this.compatibleLoadersState();
    if (state.phase !== 'loaded') {
      return null;
    }
    const selectedLoader = this.modLoader()?.toLowerCase();
    if (!selectedLoader || selectedLoader === 'vanilla') {
      return null;
    }
    const loaderData = state.data.find(d => d.loader === selectedLoader);
    return loaderData ? loaderData.versions : null;
  });

  // A failed loader fetch must not look like a harmless empty list: this flag
  // renders a translated message naming the safe next action, while vanilla
  // stays selectable so the assistant is not stuck in an unclear load error.
  public readonly loadersFailed = computed(() => this.compatibleLoadersState().phase === 'failed');

  constructor() {
    // Every entry into the assistant starts from a clean state: leftovers from
    // another page sharing this root-provided state (for example the instance
    // detail settings) must not pre-fill the form or disable creation. The
    // component is constructed once per visit, so back-navigation while the
    // same assistant is still running keeps its confirmed inputs.
    this.state.reset();

    // Effect to reset the loader version when the mod loader changes and to
    // keep its required validator aligned with the backend contract: a
    // non-vanilla loader without a loader version is rejected with HTTP 400,
    // while a missing loader falls back to vanilla and needs none.
    effect(() => {
      const loader = this.modLoader();
      const loaderVersionControl = this.form.controls.loaderVersion;
      loaderVersionControl.setValidators(requiresLoaderVersion(loader) ? [Validators.required] : []);
      loaderVersionControl.setValue('');
    });
  }

  public createProject(): void {
    // The submit button is already locked while the form is invalid; this
    // guard keeps programmatic calls from sending the undefined fields the
    // backend would have to reject or fill with fallbacks.
    if (this.form.invalid || this.isSubmitting() || this.projectCreated()) {
      return;
    }
    this.statusMessage.set(null);
    this.statusType.set(null);
    this.isSubmitting.set(true);

    const value = this.form.getRawValue();
    const request: CreateInstanceRequest = {
      name: value.name || undefined,
      description: value.description || undefined,
      gameVersion: value.minecraftVersion || undefined,
      modLoader: this.state.toBackendModLoader(value.modLoader) || undefined,
      modLoaderVersion: value.loaderVersion || undefined,
    };

    this.apiService.createInstance(request).pipe(
      // A late response after the user left the assistant must neither touch
      // the state nor pull them to the created instance from elsewhere.
      takeUntilDestroyed(this.destroyRef),
      finalize(() => this.isSubmitting.set(false))
    ).subscribe({
      next: response => {
        this.state.setBootstrapResponse(response);
        this.statusMessage.set('NEW_INSTANCE.CREATE_PROJECT_SUCCESS');
        this.statusType.set('success');
        this.patchFormFromState();
        // The bootstrap response carries the created instance; the assistant
        // ends by opening it, so a second click cannot create a duplicate.
        const createdId = response.instance?.id;
        if (createdId) {
          this.router.navigate(['/instance', createdId]);
        }
      },
      error: () => {
        this.statusMessage.set('NEW_INSTANCE.CREATE_PROJECT_ERROR');
        this.statusType.set('error');
      }
    });
  }

  private patchFormFromState(): void {
    const instance = this.state.instance();
    if (!instance) {
      return;
    }
    this.form.patchValue({
      name: instance.name ?? '',
      description: instance.description ?? '',
      minecraftVersion: instance.gameVersion ?? '',
      modLoader: instance.modLoader ? this.toFormModLoader(instance.modLoader) : '',
      loaderVersion: instance.modLoaderVersion ?? ''
    }, { emitEvent: false });
  }

  private toFormModLoader(loader: ModLoader): string {
    switch (loader) {
      case ModLoader.FABRIC:
        return 'Fabric';
      case ModLoader.FORGE:
        return 'Forge';
      case ModLoader.NEOFORGE:
        return 'NeoForge';
      case ModLoader.QUILT:
        return 'Quilt';
      case ModLoader.VANILLA:
      default:
        return 'Vanilla';
    }
  }
}
