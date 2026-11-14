export enum ModLoader {
  VANILLA = 'Vanilla',
  FORGE = 'Forge',
  NEOFORGE = 'NeoForge',
  FABRIC = 'Fabric',
  QUILT = 'Quilt'
}

export interface Instance {
  id?: string;
  name?: string;
  categories?: string[];
  description?: string;
  gameVersion?: string;
  modLoader?: ModLoader;
  modLoaderVersion?: string;
  modsCount?: number;
  javaXmx?: string;
  javaXms?: string;
  javaPath?: string;
}

export interface CreateInstanceRequest {
  name?: string;
  description?: string;
  gameVersion?: string;
  modLoader?: string;
  modLoaderVersion?: string;
  javaPath?: string;
}

export interface UpdateInstanceRequest extends CreateInstanceRequest {
  javaXmx?: string;
  javaXms?: string;
}
