import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  OnDestroy,
  Output,
  ViewChild,
  computed,
  effect,
  input,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { ModrinthSearchHit } from '../../models/modrinth/modrinth-search.model';
import { TranslatePipe } from '@ngx-translate/core';
import { ModCardSkeletonComponent } from '../mod-card-skeleton/mod-card-skeleton';
import { ModResultCardComponent } from '../mod-result-card/mod-result-card.component';

@Component({
  selector: 'app-mod-list',
  standalone: true,
  imports: [
    CommonModule,
    MatIconModule,
    MatProgressSpinnerModule,
    TranslatePipe,
    ModCardSkeletonComponent,
    ModResultCardComponent,
  ],
  templateUrl: './mod-list.component.html',
  styleUrls: ['./mod-list.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ModListComponent implements OnDestroy {
  readonly mods = input.required<ModrinthSearchHit[]>();
  readonly virtualScroll = input<boolean>(false);
  readonly totalAvailable = input<number | null>(null);
  readonly loadingMore = input<boolean>(false);
  readonly showEmptyState = input<boolean>(true);
  readonly loading = input<boolean>(false);
  readonly skeletonCount = input<number>(4);

  @Output() readonly addMod = new EventEmitter<ModrinthSearchHit>();
  @Output() readonly showDetails = new EventEmitter<string>();
  @Output() readonly loadMore = new EventEmitter<void>();

  @ViewChild('sentinel') set sentinelRef(sentinel: ElementRef<HTMLDivElement> | undefined) {
    if (this.sentinel === sentinel) {
      return;
    }
    this.sentinel = sentinel;
    if (this.virtualScroll()) {
      queueMicrotask(() => this.observeSentinel());
    }
  }

  private sentinel?: ElementRef<HTMLDivElement>;
  private observer: IntersectionObserver | null = null;

  protected readonly skeletons = computed(() => {
    const count = Math.max(1, this.skeletonCount());
    return Array.from({ length: count });
  });

  constructor(private readonly ngZone: NgZone) {
    effect(() => {
      if (this.virtualScroll()) {
        queueMicrotask(() => this.observeSentinel());
      } else {
        queueMicrotask(() => this.disconnectObserver());
      }
    });
  }

  ngOnDestroy(): void {
    this.disconnectObserver();
  }

  protected trackByProjectId = (_: number, mod: ModrinthSearchHit) => mod.project_id;

  protected onAddMod(mod: ModrinthSearchHit): void {
    this.addMod.emit(mod);
  }

  protected onShowDetails(projectId: string): void {
    this.showDetails.emit(projectId);
  }

  private observeSentinel(): void {
    const sentinelEl = this.sentinel?.nativeElement;
    if (!sentinelEl || !this.virtualScroll()) {
      return;
    }

    if (!this.observer) {
      this.observer = new IntersectionObserver(
        entries => {
          for (const entry of entries) {
            if (entry.isIntersecting) {
              this.ngZone.run(() => this.tryLoadMore());
              break;
            }
          }
        },
        { root: null, rootMargin: '0px 0px 240px 0px', threshold: 0 }
      );
    } else {
      this.observer.disconnect();
    }

    this.observer.observe(sentinelEl);
  }

  private disconnectObserver(): void {
    if (this.observer) {
      this.observer.disconnect();
    }
    this.observer = null;
  }

  private tryLoadMore(): void {
    if (!this.virtualScroll() || this.loadingMore()) {
      return;
    }

    const mods = this.mods();
    const total = this.totalAvailable() ?? mods.length;
    if (mods.length >= total) {
      this.disconnectObserver();
      return;
    }

    this.loadMore.emit();
  }
}
