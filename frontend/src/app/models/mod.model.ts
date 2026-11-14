import { ModDataProvider } from './mod-data-provider';

export interface InstalledMod {
  projectId: string;
  projectSlug?: string;
  displayName?: string;
  versionId: string;
  fileName?: string;
  versionNumber?: string;
  dependencies: string[];
  downloadUrl?: string;
  sha1?: string;
  sha512?: string;
  size?: number;
  installedAt?: string;
  provider?: ModDataProvider;
  downloaded?: boolean;
  clientSideOnly?: boolean;
}

export interface InstallModRequest {
  projectId: string;
  versionId?: string;
  provider?: ModDataProvider;
}
