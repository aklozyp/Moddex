import { ChangeDetectionStrategy, Component, DestroyRef, computed, effect, inject, signal } from '@angular/core';
import { toSignal, takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { ActivatedRoute, Router } from '@angular/router';
import { ModrinthService } from '../../services/modrinth.service';
import { ApiService } from '../../services/api-service';
import { ModrinthSearchHit, ModrinthSearchResponse } from '../../models/modrinth/modrinth-search.model';
import { PageEvent } from '@angular/material/paginator';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatMenuModule } from '@angular/material/menu';
import { MatPaginatorModule } from '@angular/material/paginator';
import { FormsModule } from '@angular/forms';
import { ModListComponent } from '../../components/mod-list/mod-list.component';
import { HttpErrorResponse } from '@angular/common/http';
import { Subject, debounceTime, finalize } from 'rxjs';
import { MatSelectModule } from '@angular/material/select';
import { MatChipsModule } from '@angular/material/chips';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatTooltipModule } from '@angular/material/tooltip';
import { MatBadgeModule } from '@angular/material/badge';
import { TranslatePipe, TranslateService } from '@ngx-translate/core';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';
import { map, takeUntil } from 'rxjs/operators';

@Component({
  selector: 'app-add-mods-page',
  templateUrl: './add-mods-page.component.html',
  styleUrls: ['./add-mods-page.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatCardModule,
    MatFormFieldModule,
    MatInputModule,
    MatButtonModule,
    MatIconModule,
    MatMenuModule,
    MatPaginatorModule,
    MatSelectModule,
    MatChipsModule,
    MatProgressSpinnerModule,
    MatTooltipModule,
    MatBadgeModule,
    MatSnackBarModule,
    ModListComponent,
    TranslatePipe,
  ],
})
export class AddModsPageComponent {
  private static readonly VIRTUAL_PAGE_SIZE = 40;

  private readonly route = inject(ActivatedRoute);
  private readonly modrinthService = inject(ModrinthService);
  private readonly apiService = inject(ApiService);
  private readonly translate = inject(TranslateService);
  private readonly snackBar = inject(MatSnackBar);
  private readonly router = inject(Router);
  private readonly destroyRef = inject(DestroyRef);

  private readonly instanceRoute = this.resolveInstanceRoute(this.route);

  private readonly instanceId = toSignal(
    this.instanceRoute.paramMap.pipe(map(params => params.get('id') ?? '')),
    { initialValue: '' }
  );

  readonly searchQuery = signal('');
  readonly selectedCategories = signal<string[]>([]);
  readonly sort = signal('relevance');
  readonly page = signal(0);
  readonly pageSize = signal<number>(25);
  readonly pageSizeOptions = [10, 25, 50, 100];

  readonly filters = toSignal(this.modrinthService.getFilters());

  readonly isAllMode = computed(() => this.pageSize() === 0);
  readonly isLoading = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly lastUpdatedAt = signal<Date | null>(null);

  private readonly pagedResult = signal<ModrinthSearchResponse | null>(null);

  readonly virtualMods = signal<ModrinthSearchResponse['hits']>([]);
  readonly virtualTotal = signal(0);
  readonly virtualOffset = signal(0);
  readonly virtualLoading = signal(false);
  readonly virtualComplete = signal(false);

  readonly mods = computed(() => this.isAllMode() ? this.virtualMods() : (this.pagedResult()?.hits ?? []));
  readonly totalMods = computed(() => this.isAllMode() ? this.virtualTotal() : (this.pagedResult()?.total_hits ?? 0));
  readonly hasResults = computed(() => this.mods().length > 0);
  readonly hasActiveFilters = computed(
    () => !!this.searchQuery().trim() || this.selectedCategories().length > 0 || this.sort() !== 'relevance'
  );
  readonly activeFiltersCount = computed(() => {
    let count = this.selectedCategories().length;
    if (this.searchQuery().trim()) {
      count += 1;
    }
    if (this.sort() !== 'relevance') {
      count += 1;
    }
    return count;
  });
  readonly resultLabel = computed(() => {
    if (!this.hasResults()) {
      return this.searchQuery().trim()
        ? this.translate.instant('ADD_MODS.RESULTS_EMPTY_SEARCH', { term: this.searchQuery().trim() })
        : this.translate.instant('ADD_MODS.RESULTS_EMPTY_RECOMMENDED');
    }
    return this.translate.instant('ADD_MODS.RESULTS_TOTAL', { count: this.totalMods() });
  });

  private readonly searchDebounce = new Subject<void>();
  private readonly pagedCancel$ = new Subject<void>();
  private readonly virtualCancel$ = new Subject<void>();


  constructor() {
    this.searchDebounce
      .pipe(debounceTime(300), takeUntilDestroyed(this.destroyRef))
      .subscribe(() => this.triggerSearch());

    effect(() => {
      const id = this.instanceId();
      if (!id) {
        return;
      }
      this.triggerSearch();
    });

    this.route.paramMap
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(() => {
        this.page.set(0);
      });
  }

  onSearchQueryChange(query: string): void {
    this.searchQuery.set(query);
    this.page.set(0);
    this.searchDebounce.next();
  }

  clearSearch(): void {
    if (!this.searchQuery().trim()) {
      return;
    }
    this.searchQuery.set('');
    this.page.set(0);
    this.triggerSearch();
  }

  clearAllFilters(): void {
    const hasChanges =
      !!this.searchQuery().trim() || this.selectedCategories().length > 0 || this.sort() !== 'relevance';
    if (!hasChanges) {
      return;
    }
    this.searchQuery.set('');
    this.selectedCategories.set([]);
    if (this.sort() !== 'relevance') {
      this.sort.set('relevance');
    }
    this.page.set(0);
    this.triggerSearch();
  }

  onPageChange(event: PageEvent): void {
    this.page.set(event.pageIndex);
    this.pageSize.set(event.pageSize);
    this.fetchPagedMods();
  }

  onSortChange(sort: string): void {
    if (this.sort() === sort) {
      return;
    }
    this.sort.set(sort);
    this.page.set(0);
    this.triggerSearch();
  }

  onPageSizeChange(size: number): void {
    if (this.pageSize() === size) {
      return;
    }
    this.pageSize.set(size);
    this.page.set(0);
    this.triggerSearch();
  }

  toggleCategory(category: string): void {
    this.selectedCategories.update(categories => {
      const next = categories.includes(category)
        ? categories.filter(c => c !== category)
        : [...categories, category];
      return next;
    });
    this.page.set(0);
    this.triggerSearch();
  }

  onAddMod(mod: ModrinthSearchHit): void {
    if (!this.instanceId()) {
      return;
    }
    this.modrinthService.installMod(this.instanceId(), mod.project_id, undefined, mod.provider)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
      next: () => {
        this.snackBar.open(this.translate.instant('ADD_MODS.INSTALL_SUCCESS'), undefined, { duration: 3000 });
      },
      error: error => {
        console.error('Failed to install mod', error);
        this.snackBar.open(this.translate.instant('ADD_MODS.INSTALL_ERROR'), undefined, { duration: 3000 });
      }
    });
  }

  onShowDetails(projectId: string): void {
    this.router.navigate(['../', projectId], { relativeTo: this.route });
  }

  navigateBack(): void {
    this.router.navigate(['../'], { relativeTo: this.route });
  }

  loadMoreVirtualMods(): void {
    if (!this.isAllMode() || this.virtualLoading() || this.virtualComplete()) {
      return;
    }
    this.loadVirtualPage();
  }

  protected triggerSearch(): void {
    const instanceId = this.instanceId();
    if (!instanceId) {
      return;
    }
    this.errorMessage.set(null);

    if (this.isAllMode()) {
      this.resetVirtualState();
      this.loadVirtualPage(true);
    } else {
      this.fetchPagedMods();
    }
  }

  private fetchPagedMods(): void {
    const instanceId = this.instanceId();
    if (!instanceId) {
      return;
    }
    const limit = this.pageSize();
    const offset = this.page() * limit;

    this.pagedCancel$.next();
    this.isLoading.set(true);
    this.errorMessage.set(null);

    this.fetchMods(limit, offset)
      .pipe(
        takeUntil(this.pagedCancel$),
        takeUntilDestroyed(this.destroyRef),
        finalize(() => this.isLoading.set(false))
      )
      .subscribe({
        next: response => {
          this.pagedResult.set(response);
          this.lastUpdatedAt.set(new Date());
        },
        error: error => {
          this.pagedResult.set(null);
          this.handleLoadError(error, 'paged');
        },
      });
  }

  private loadVirtualPage(initial = false): void {
    const instanceId = this.instanceId();
    if (!instanceId) {
      return;
    }

    const offset = initial ? 0 : this.virtualOffset();
    if (!initial && this.virtualLoading()) {
      return;
    }

    if (this.virtualComplete()) {
      return;
    }

    if (initial) {
      this.virtualCancel$.next();
      this.isLoading.set(true);
    }
    this.virtualLoading.set(true);
    this.errorMessage.set(null);

    this.fetchMods(AddModsPageComponent.VIRTUAL_PAGE_SIZE, offset)
      .pipe(
        takeUntil(this.virtualCancel$),
        takeUntilDestroyed(this.destroyRef),
        finalize(() => {
          this.virtualLoading.set(false);
          if (initial) {
            this.isLoading.set(false);
          }
        })
      )
      .subscribe({
        next: response => {
          const combined = initial ? response.hits : [...this.virtualMods(), ...response.hits];
          this.virtualMods.set(combined);
          this.virtualTotal.set(response.total_hits);
          const nextOffset = response.offset + response.hits.length;
          this.virtualOffset.set(nextOffset);
          this.virtualComplete.set(nextOffset >= response.total_hits);
          this.lastUpdatedAt.set(new Date());
        },
        error: error => {
          this.handleLoadError(error, 'virtual');
        },
      });
  }

  private resetVirtualState(): void {
    this.virtualMods.set([]);
    this.virtualTotal.set(0);
    this.virtualOffset.set(0);
    this.virtualComplete.set(false);
    this.virtualLoading.set(false);
  }

  private fetchMods(limit: number, offset: number) {
    const instanceId = this.instanceId();
    const query = this.searchQuery().trim();
    const categories = this.selectedCategories();
    const index = this.sort();

    if (!instanceId) {
      throw new Error('Instance id not available');
    }

    if (query) {
      return this.modrinthService.searchMods(instanceId, query, limit, offset, { categories, index });
    }

    return this.modrinthService.getRecommendedMods(instanceId, limit, offset, { categories, index });
  }

  private resolveInstanceRoute(route: ActivatedRoute): ActivatedRoute {
    let current: ActivatedRoute | null = route;
    while (current && !current.snapshot.paramMap.has('id')) {
      current = current.parent;
    }
    return current ?? route;
  }

  private handleLoadError(error: unknown, context: 'paged' | 'virtual'): void {
    console.error('Failed to load mods', error);
    const errorKey = this.resolveErrorKey(error);
    const message = this.translate.instant(errorKey);
    this.errorMessage.set(message);

    const snack = this.snackBar.open(message, this.translate.instant('RETRY'), {
      duration: 5000,
      panelClass: ['snackbar-error'],
    });

    snack
      .onAction()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(() => this.triggerSearch());

    if (context === 'virtual') {
      if (!this.virtualMods().length) {
        this.virtualMods.set([]);
      }
    }
  }

  private resolveErrorKey(error: unknown): string {
    if (error instanceof HttpErrorResponse) {
      if (error.status === 0) {
        return 'ADD_MODS.ERROR_NETWORK';
      }
      if (error.status === 429) {
        return 'ADD_MODS.ERROR_RATE_LIMIT';
      }
    }
    return 'ADD_MODS.LOAD_ERROR';
  }

}
