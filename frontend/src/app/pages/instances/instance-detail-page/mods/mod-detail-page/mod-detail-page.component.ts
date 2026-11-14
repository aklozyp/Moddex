import { ChangeDetectionStrategy, Component, DestroyRef, computed, effect, inject, signal } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { toSignal, takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { map, distinctUntilChanged } from 'rxjs/operators';
import { ModrinthService, ModrinthProjectDetailsResponse } from '../../../../../services/modrinth.service';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatChipsModule } from '@angular/material/chips';
import { MatTooltipModule } from '@angular/material/tooltip';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { CommonModule, NgOptimizedImage } from '@angular/common';
import { SafeHtmlPipe } from '../../../../../pipes/safe-html.pipe';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';
import { TranslatePipe, TranslateService } from '@ngx-translate/core';
import { ModrinthVersion } from '../../../../../models/modrinth/modrinth-version.model';
import { ModrinthProject } from '../../../../../models/modrinth/modrinth-project.model';

import { MatTableModule } from '@angular/material/table';

import { MarkdownPipe } from '../../../../../pipes/markdown.pipe';

@Component({
  selector: 'app-mod-detail-page',
  standalone: true,
  imports: [
    CommonModule,
    NgOptimizedImage,
    MatButtonModule,
    MatIconModule,
    MatChipsModule,
    MatTooltipModule,
    MatProgressSpinnerModule,
    MatSnackBarModule,
    MatTableModule,
    SafeHtmlPipe,
    TranslatePipe,
    MarkdownPipe,
  ],
  templateUrl: './mod-detail-page.component.html',
  styleUrls: ['./mod-detail-page.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ModDetailPageComponent {
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly modrinthService = inject(ModrinthService);
  private readonly snackBar = inject(MatSnackBar);
  private readonly translate = inject(TranslateService);
  private readonly destroyRef = inject(DestroyRef);

  private readonly instanceRoute = this.resolveInstanceRoute(this.route);

  private readonly instanceId = toSignal(
    this.instanceRoute.paramMap.pipe(
      map(params => params.get('id') ?? ''),
      distinctUntilChanged()
    ),
    { initialValue: this.instanceRoute.snapshot.paramMap.get('id') ?? '' }
  );
  private readonly projectId = toSignal(
    this.route.paramMap.pipe(
      map(params => params.get('modId') ?? ''),
      distinctUntilChanged()
    ),
    { initialValue: this.route.snapshot.paramMap.get('modId') ?? '' }
  );

  readonly isLoading = signal(true);
  readonly errorMessage = signal<string | null>(null);
  readonly details = signal<ModrinthProjectDetailsResponse | null>(null);
  readonly installingLatest = signal(false);
  readonly installingVersionId = signal<string | null>(null);
  readonly installedVersion = signal<ModrinthVersion | null>(null);

  readonly displayedColumns: string[] = ['name', 'version', 'date', 'actions'];

  readonly project = computed<ModrinthProject | null>(() => this.details()?.project ?? null);
  readonly versions = computed<ModrinthVersion[]>(() => this.details()?.versions ?? []);

  constructor() {
    effect(() => {
      const instanceId = this.instanceId();
      const projectId = this.projectId();
      if (!instanceId || !projectId) {
        return;
      }
      this.loadDetails(instanceId, projectId);
      this.loadInstalledVersion(instanceId, projectId);
    });
  }

  private loadInstalledVersion(instanceId: string, projectId: string): void {
    this.modrinthService.getInstalledMods(instanceId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: mods => {
          const installedMod = mods.find(mod => mod.projectId === projectId);
          if (installedMod) {
            this.modrinthService.getModDetails(instanceId, projectId)
              .pipe(takeUntilDestroyed(this.destroyRef))
              .subscribe({
                next: details => {
                  const installedVersion = details.versions.find(version => version.id === installedMod.versionId);
                  this.installedVersion.set(installedVersion || null);
                }
              });
          }
        }
      });
  }

  navigateToAdd(): void {
    this.router.navigate(['../add'], { relativeTo: this.route });
  }

  navigateToInstalled(): void {
    this.router.navigate(['../'], { relativeTo: this.route });
  }

  openModrinthProject(slug?: string): void {
    if (!slug) {
      return;
    }
    window.open('https://modrinth.com/mod/' + slug, '_blank');
  }

  installLatest(): void {
    const instanceId = this.instanceId();
    const projectId = this.projectId();
    const provider = this.details()?.provider;
    if (!instanceId || !projectId || this.installingLatest()) {
      return;
    }
    this.installingLatest.set(true);
    this.modrinthService.installMod(instanceId, projectId, undefined, provider)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.snackBar.open(this.translate.instant('MOD_DETAIL.INSTALL_LATEST_SUCCESS'), undefined, { duration: 3000 });
        },
        error: error => {
          console.error('Failed to install latest mod version', error);
          this.snackBar.open(this.translate.instant('MOD_DETAIL.INSTALL_ERROR'), undefined, { duration: 3000 });
          this.installingLatest.set(false);
        },
        complete: () => this.installingLatest.set(false)
      });
  }

  installSpecificVersion(version: ModrinthVersion): void {
    const instanceId = this.instanceId();
    const projectId = this.projectId();
    const provider = this.details()?.provider;
    if (!instanceId || !projectId || this.installingVersionId() === version.id) {
      return;
    }
    this.installingVersionId.set(version.id);
    this.modrinthService.installMod(instanceId, projectId, version.id, provider)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => {
          this.snackBar.open(this.translate.instant('MOD_DETAIL.INSTALL_VERSION_SUCCESS'), undefined, { duration: 3000 });
        },
        error: error => {
          console.error('Failed to install mod version', error);
          this.snackBar.open(this.translate.instant('MOD_DETAIL.INSTALL_ERROR'), undefined, { duration: 3000 });
          this.installingVersionId.set(null);
        },
        complete: () => this.installingVersionId.set(null)
      });
  }

  trackVersion(_: number, version: ModrinthVersion): string {
    return version.id;
  }

  private resolveInstanceRoute(route: ActivatedRoute): ActivatedRoute {
    let current: ActivatedRoute | null = route;
    while (current && !current.snapshot.paramMap.has('id')) {
      current = current.parent;
    }
    return current ?? route;
  }

  private loadDetails(instanceId: string, projectId: string): void {
    this.isLoading.set(true);
    this.errorMessage.set(null);
    this.details.set(null);

    this.modrinthService.getModDetails(instanceId, projectId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: response => {
          this.details.set(response);
          this.isLoading.set(false);
        },
        error: error => {
          console.error('Failed to load mod details', error);
          this.errorMessage.set(this.translate.instant('MOD_DETAIL.LOAD_ERROR'));
          this.isLoading.set(false);
        }
      });
  }
}
