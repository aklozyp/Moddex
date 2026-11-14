import { computed, Injectable, signal } from '@angular/core';
import { Instance, ModLoader } from '../../../models/instance';
import { InstanceBootstrapResponse } from '../../../models/instance-bootstrap';
import { ServerPropertiesDto } from '../../../models/server-properties';

const backendToFrontend: Record<string, ModLoader> = {
  VANILLA: ModLoader.VANILLA,
  FABRIC: ModLoader.FABRIC,
  FORGE: ModLoader.FORGE,
  QUILT: ModLoader.QUILT,
  NEOFORGE: ModLoader.NEOFORGE,
};

const frontendToBackend: Record<ModLoader, string> = {
  [ModLoader.VANILLA]: 'Vanilla',
  [ModLoader.FORGE]: 'Forge',
  [ModLoader.NEOFORGE]: 'NeoForge',
  [ModLoader.FABRIC]: 'Fabric',
  [ModLoader.QUILT]: 'Quilt',
};

@Injectable({ providedIn: 'root' })
export class NewInstanceStateService {
  private readonly instanceState = signal<Instance | null>(null);
  private readonly propertiesState = signal<ServerPropertiesDto | null>(null);
  private readonly instanceLoadingState = signal(false);

  public readonly instance = computed(() => this.instanceState());
  public readonly serverProperties = computed(() => this.propertiesState());
  public readonly isProjectCreated = computed(() => this.instanceState() !== null);
  public readonly instanceId = computed(() => this.instanceState()?.id ?? null);
  public readonly isInstanceLoading = computed(() => this.instanceLoadingState());

  setBootstrapResponse(response: InstanceBootstrapResponse): void {
    this.setInstance(response.instance);
    this.propertiesState.set(response.serverProperties);
  }

  setInstance(instance: Instance | null): void {
    this.instanceState.set(instance ? this.normalizeInstance(instance) : null);
  }

  setInstanceLoading(loading: boolean): void {
    this.instanceLoadingState.set(loading);
  }

  updateServerProperties(dto: ServerPropertiesDto): void {
    this.propertiesState.set(dto);
  }

  clearServerProperties(): void {
    this.propertiesState.set(null);
  }

  reset(): void {
    this.setInstance(null);
    this.propertiesState.set(null);
    this.instanceLoadingState.set(false);
  }

  toBackendModLoader(value: string | null | undefined): string | undefined {
    if (!value) {
      return undefined;
    }
    const upperValue = value.toUpperCase();
    const mappedValue = frontendToBackend[upperValue as ModLoader];
    return mappedValue ? mappedValue.toUpperCase() : upperValue;
  }

  private normalizeInstance(instance: Instance): Instance {
    if (!instance.modLoader) {
      return instance;
    }
    const normalized = backendToFrontend[(instance.modLoader as unknown as string)?.toUpperCase()] ?? instance.modLoader;
    return {
      ...instance,
      modLoader: normalized,
    };
  }
}
