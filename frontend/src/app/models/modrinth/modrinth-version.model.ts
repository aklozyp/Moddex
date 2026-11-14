import { ModDataProvider } from '../mod-data-provider';

export interface ModrinthVersion {
  id: string;
  project_id: string;
  author_id?: string;
  featured?: boolean;
  name?: string;
  version_number: string;
  changelog?: string;
  changelog_url?: string;
  date_published?: string;
  downloads?: number;
  version_type?: string;
  status?: string;
  loaders: string[];
  game_versions: string[];
  files: ModrinthFile[];
  dependencies: ModrinthDependency[];
  provider?: ModDataProvider;
}

export interface ModrinthFile {
  hashes?: {
    sha1?: string;
    sha512?: string;
  };
  url: string;
  filename: string;
  primary?: boolean;
  size?: number;
}

export interface ModrinthDependency {
  version_id?: string;
  project_id?: string;
  file_name?: string;
  dependency_type: string;
}
