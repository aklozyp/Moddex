import { Component, DestroyRef, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterOutlet } from '@angular/router';
import { ApiService } from '../../../services/api-service';
import { Instance } from '../../../models/instance';
import { Sidebar, SidebarNavigationItem } from '../../../components/sidebar/sidebar';
import { NewInstanceStateService } from '../new-instance/new-instance-state.service';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

@Component({
  selector: 'app-instance-detail-page',
  imports: [
    RouterOutlet,
    Sidebar
  ],
  templateUrl: './instance-detail-page.html',
  standalone: true,
  styleUrl: './instance-detail-page.scss'
})
export class InstanceDetailPage {

  private apiService = inject(ApiService)

  private readonly state = inject(NewInstanceStateService);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);

  instance = signal<Instance | undefined>(undefined)
  public readonly navigationItems = computed<SidebarNavigationItem[]>(() => [
    { label: 'Console', path: 'console' },
    { label: 'Files', path: 'files' },
    { label: 'Backups', path: 'backups' },
    { label: 'INSTANCE_DETAIL.MODS', path: 'mods' },
    { label: 'INSTANCE_DETAIL.INSTANCE_SETTINGS', path: 'instance-settings' },
    { label: 'INSTANCE_DETAIL.SERVER_SETTINGS', path: 'server-settings' },
  ]);


  constructor() {
    this.route.paramMap
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(params => {
        const instanceId = params.get('id');
        if (!instanceId) {
          return;
        }
        this.state.clearServerProperties();
        this.loadInstance(instanceId);
        this.loadServerProperties(instanceId);
      });
  }

  ngOnDestroy(): void {
    this.state.reset();
  }

  private async loadInstance(instanceId: string): Promise<void> {
    this.state.setInstanceLoading(true);
    try {
      const instance = await this.apiService.getInstanceById(instanceId);
      this.instance.set(instance);
      this.state.setInstance(instance);
    } catch (error) {
      console.error('Failed to load instance', error);
      this.instance.set(undefined);
      this.state.setInstance(null);
    } finally {
      this.state.setInstanceLoading(false);
    }
  }

  private loadServerProperties(instanceId: string): void {
    this.apiService.getServerProperties(instanceId)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: dto => this.state.updateServerProperties(dto),
        error: error => console.error('Failed to load server.properties', error),
      });
  }
}
