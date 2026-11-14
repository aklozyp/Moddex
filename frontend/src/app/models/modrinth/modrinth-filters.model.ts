export interface ModrinthFiltersResponse {
  loaders: ModrinthLoaderTag[];
  gameVersions: ModrinthGameVersionTag[];
  categories: ModrinthCategoryTag[];
}

export interface ModrinthTag {
  icon: string;
  name: string;
  project_type: string;
}

export type ModrinthLoaderTag = ModrinthTag;

export interface ModrinthGameVersionTag {
  version: string;
  version_type: string;
  major: boolean;
}

export interface ModrinthCategoryTag {
  icon: string;
  name: string;
  project_type: string;
}
