import { ModDataProvider } from '../mod-data-provider';

export interface ModrinthSearchResponse {
  hits: ModrinthSearchHit[];
  offset: number;
  limit: number;
  total_hits: number;
}

export interface ModrinthSearchHit {
  project_id: string;
  project_type: string;
  slug: string;
  title: string;
  description?: string;
  author?: string;
  versions?: string[];
  downloads?: number;
  follows?: number;
  icon_url?: string;
  date_created?: string;
  date_modified?: string;
  latest_version?: string;
  license?: string;
  client_side?: string;
  server_side?: string;
  gallery?: string[];
  featured_gallery?: string;
  color?: number;
  provider?: ModDataProvider;
}
