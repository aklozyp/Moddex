import { ModDataProvider } from '../mod-data-provider';

export interface ModrinthProject {
  id: string;
  slug: string;
  project_type: string;
  team?: string;
  title: string;
  description?: string;
  body?: string;
  body_url?: string;
  published?: string;
  updated?: string;
  status?: string;
  license?: {
    id?: string;
    name?: string;
    url?: string;
  };
  client_side?: string;
  server_side?: string;
  downloads?: number;
  followers?: number;
  categories?: string[];
  versions?: string[];
  game_versions?: string[];
  icon_url?: string;
  color?: number;
  gallery?: {
    url: string;
    featured: boolean;
    title: string;
    description: string;
    created: string;
  }[];
  provider?: ModDataProvider;
}
