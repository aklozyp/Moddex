import { ChangeDetectionStrategy, Component, DestroyRef, computed, effect, inject, signal, ElementRef, ViewChild } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { TranslatePipe } from '@ngx-translate/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';
import { MatTooltipModule } from '@angular/material/tooltip';
import { MatDialog } from '@angular/material/dialog';
import { InstalledMod } from '../../../../models/mod.model';
import { ModrinthService } from '../../../../services/modrinth.service';
import { InstalledModListComponent } from '../../../../components/installed-mod-list/installed-mod-list.component';
import { NewInstanceStateService } from '../../new-instance/new-instance-state.service';
import { takeUntilDestroyed, toSignal } from '@angular/core/rxjs-interop';
import { map } from 'rxjs/operators';
import { CommonModule } from '@angular/common';
import { TranslateService } from '@ngx-translate/core';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatMenuModule } from '@angular/material/menu';
import { MatButtonToggleChange, MatButtonToggleModule } from '@angular/material/button-toggle';
import { firstValueFrom } from 'rxjs';
import { ApiService } from '../../../../services/api-service';
import {
  SecurityReviewDialogComponent,
  SecurityReviewData,
} from '../../../../components/security-review-dialog/security-review-dialog.component';

@Component({
  selector: 'app-instance-mods-page',
  standalone: true,
  imports: [
    CommonModule,
    MatButtonModule,
    MatIconModule,
    MatProgressSpinnerModule,
    MatTooltipModule,
    MatSnackBarModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonToggleModule,
    InstalledModListComponent,
    TranslatePipe,
    MatMenuModule,
  ],
  templateUrl: './mods.html',
  styleUrls: ['./mods.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class InstanceModsPageComponent {
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly modrinthService = inject(ModrinthService);
  private readonly snackBar = inject(MatSnackBar);
  private readonly translate = inject(TranslateService);
  private readonly state = inject(NewInstanceStateService);
  private readonly destroyRef = inject(DestroyRef);
  private readonly apiService = inject(ApiService);
  private readonly dialog = inject(MatDialog);

  @ViewChild('modpackFileInput') private readonly modpackFileInput!: ElementRef<HTMLInputElement>;

  private readonly routeInstanceId = toSignal(
    this.route.parent!.paramMap.pipe(map(params => params.get('id') ?? '')),
    { initialValue: '' }
  );

  readonly instance = this.state.instance;
  readonly instanceId = computed(() => this.state.instanceId() ?? this.routeInstanceId());

  readonly isLoading = signal(true);
  readonly isRefreshing = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly installedMods = signal<InstalledMod[]>([]);
  readonly removingIds = signal<string[]>([]);
  readonly searchTerm = signal('');
  readonly sortOption = signal<SortOption>('recent');
  readonly lastSyncedAt = signal<Date | null>(null);
  readonly downloadingFormat = signal<'modrinth' | 'curseforge' | null>(null);
  readonly isDownloading = computed(() => this.downloadingFormat() !== null);
  readonly isImporting = signal(false);

  readonly filteredMods = computed(() => {
    const mods = [...this.installedMods()];
    const term = this.searchTerm().trim().toLowerCase();
    let filtered = mods;

    if (term) {
      filtered = filtered.filter(mod => {
        const name = (mod.displayName || mod.projectSlug || mod.projectId || '').toLowerCase();
        const slug = (mod.projectSlug || '').toLowerCase();
        const version = (mod.versionNumber || '').toLowerCase();
        return name.includes(term) || slug.includes(term) || version.includes(term);
      });
    }

    const option = this.sortOption();

    if (option === 'alphabetical') {
      filtered.sort((a, b) => this.displayName(a).localeCompare(this.displayName(b)));
    } else if (option === 'oldest') {
      filtered.sort((a, b) => this.installedAtTimestamp(a) - this.installedAtTimestamp(b) || this.displayName(a).localeCompare(this.displayName(b)));
    } else {
      filtered.sort((a, b) => this.installedAtTimestamp(b) - this.installedAtTimestamp(a) || this.displayName(a).localeCompare(this.displayName(b)));
    }

    return filtered;
  });

  readonly hasSearch = computed(() => this.searchTerm().trim().length > 0);
  readonly visibleCount = computed(() => this.filteredMods().length);
  readonly totalDependencies = computed(() =>
    this.installedMods().reduce((sum, mod) => sum + (mod.dependencies?.length ?? 0), 0)
  );
  readonly latestInstallation = computed(() => {
    const timestamps = this.installedMods()
      .map(mod => this.installedAtTimestamp(mod))
      .filter(timestamp => timestamp > 0);
    if (!timestamps.length) {
      return null;
    }
    return new Date(Math.max(...timestamps));
  });

  constructor() {
    effect(() => {
      const id = this.instanceId();
      if (!id) {
        return;
      }
      this.loadInstalledMods(id, { initial: true });
    });
  }

  refresh(): void {
    const id = this.instanceId();
    if (!id) {
      return;
    }
    this.loadInstalledMods(id);
  }

  navigateToAddMods(): void {
    this.router.navigate(['add'], { relativeTo: this.route });
  }

  triggerModpackImport(): void {
    this.modpackFileInput.nativeElement.click();
  }

  async onModpackFileSelected(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;

    const instanceId = this.instanceId();
    if (!instanceId || this.isImporting()) return;

    const isMrpack = file.name.endsWith('.mrpack');
    const sizeLabel = this.formatFileSize(file.size);

    const reviewData: SecurityReviewData = {
      titleKey: 'SECURITY_REVIEW.IMPORT_TITLE',
      descriptionKey: 'SECURITY_REVIEW.IMPORT_DESCRIPTION',
      descriptionParams: { name: file.name, size: sizeLabel },
      warnings: [
        {
          level: 'critical',
          message: this.translate.instant('SECURITY_REVIEW.IMPORT_WARN_REPLACE'),
        },
        {
          level: 'warning',
          message: this.translate.instant(
            isMrpack
              ? 'SECURITY_REVIEW.IMPORT_WARN_EXTERNAL_DOWNLOAD'
              : 'SECURITY_REVIEW.IMPORT_WARN_UNKNOWN_FORMAT',
          ),
        },
        {
          level: 'info',
          message: this.translate.instant('SECURITY_REVIEW.IMPORT_INFO_BACKUP'),
        },
      ],
      requireCheckbox: true,
      confirmLabelKey: 'SECURITY_REVIEW.IMPORT_CONFIRM_LABEL',
    };

    const confirmed = await firstValueFrom(
      this.dialog
        .open(SecurityReviewDialogComponent, { data: reviewData, maxWidth: '600px' })
        .afterClosed(),
    );

    if (!confirmed) return;

    this.isImporting.set(true);
    this.apiService
      .importModpack(instanceId, file)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.snackBar.open(
            this.translate.instant('ADD_MODS.IMPORT_SUCCESS'),
            undefined,
            { duration: 3000 },
          );
          this.isImporting.set(false);
          this.loadInstalledMods(instanceId);
        },
        error: (err: unknown) => {
          console.error('Failed to import modpack', err);
          const detail =
            err instanceof Error
              ? err.message
              : this.translate.instant('ADD_MODS.IMPORT_ERROR');
          this.snackBar.open(detail, undefined, { duration: 6000 });
          this.isImporting.set(false);
        },
      });
  }

  private formatFileSize(bytes: number): string {
    if (!bytes) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`;
  }

  openModDetails(mod: InstalledMod): void {
    const id = mod.projectSlug || mod.projectId;
    this.router.navigate([id], { relativeTo: this.route });
  }

  onSearch(term: string): void {
    this.searchTerm.set(term);
  }

  clearSearch(): void {
    this.searchTerm.set('');
  }

  onSortChange(change: MatButtonToggleChange): void {
    this.sortOption.set(change.value as SortOption);
  }

  protected isDownloadingFormat(format: 'modrinth' | 'curseforge'): boolean {
    return this.downloadingFormat() === format;
  }

  protected async onDownloadModpack(format: 'modrinth' | 'curseforge'): Promise<void> {
    const instanceId = this.instanceId();
    if (!instanceId || this.isDownloading()) {
      return;
    }

    this.downloadingFormat.set(format);
    try {
      const response = await firstValueFrom(this.apiService.downloadModpack(instanceId, format));
      const blob = response.body ?? new Blob();
      const filename =
        this.extractFilename(response.headers.get('Content-Disposition')) ??
        `moddex-pack-${format}.${format === 'modrinth' ? 'mrpack' : 'zip'}`;
      this.triggerDownload(blob, filename);
      this.snackBar.open(this.translate.instant('ADD_MODS.EXPORT_SUCCESS'), undefined, { duration: 2500 });
    } catch (error) {
      console.error('Failed to export modpack', error);
      const message = this.translate.instant('ADD_MODS.EXPORT_ERROR');
      this.snackBar.open(message, undefined, { duration: 4000 });
    } finally {
      this.downloadingFormat.set(null);
    }
  }

  private extractFilename(contentDisposition: string | null): string | null {
    if (!contentDisposition) {
      return null;
    }
    const match = /filename\*?="?([^\";]+)"?/i.exec(contentDisposition);
    return match?.[1] ?? null;
  }

  private triggerDownload(blob: Blob, filename: string) {
    const url = URL.createObjectURL(blob);
    try {
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filename;
      anchor.style.display = 'none';
      document.body.appendChild(anchor);
      anchor.click();
      document.body.removeChild(anchor);
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  removeMod(mod: InstalledMod): void {
    const instanceId = this.instanceId();
    if (!instanceId || this.removingIds().includes(mod.projectId)) {
      return;
    }

    this.removingIds.update(ids => [...ids, mod.projectId]);

    this.modrinthService.removeMod(instanceId, mod.projectId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.snackBar.open(this.translate.instant('INSTANCE_MODS.REMOVE_SUCCESS'), undefined, { duration: 3000 });
          this.removingIds.update(ids => ids.filter(id => id !== mod.projectId));
          this.loadInstalledMods(instanceId);
        },
        error: error => {
          console.error('Failed to remove mod', error);
          this.snackBar.open(this.translate.instant('INSTANCE_MODS.REMOVE_ERROR'), undefined, { duration: 3000 });
          this.removingIds.update(ids => ids.filter(id => id !== mod.projectId));
        }
      });
  }

  private loadInstalledMods(instanceId: string, options: { initial?: boolean } = {}): void {
    const { initial = false } = options;
    if (initial) {
      this.isLoading.set(true);
    } else {
      this.isRefreshing.set(true);
    }
    this.errorMessage.set(null);

    this.modrinthService.getInstalledMods(instanceId)
      .pipe(
        takeUntilDestroyed(this.destroyRef),
      )
      .subscribe({
        next: mods => {
          this.installedMods.set(mods);
          this.isLoading.set(false);
          this.isRefreshing.set(false);
          this.lastSyncedAt.set(new Date());
        },
        error: error => {
          console.error('Failed to load installed mods', error);
          this.errorMessage.set(this.translate.instant('INSTANCE_MODS.LOAD_ERROR'));
          this.isLoading.set(false);
          this.isRefreshing.set(false);
        },
      });
  }

  private displayName(mod: InstalledMod): string {
    return mod.displayName || mod.projectSlug || mod.projectId;
  }

  private installedAtTimestamp(mod: InstalledMod): number {
    if (!mod.installedAt) {
      return 0;
    }
    const parsed = Date.parse(mod.installedAt);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
}

type SortOption = 'recent' | 'alphabetical' | 'oldest';
