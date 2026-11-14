export type ServerPropertyType = 'STRING' | 'INTEGER' | 'BOOLEAN' | 'ENUM';

export interface ServerPropertiesDto {
  categories: ServerPropertyCategory[];
}

export interface ServerPropertyCategory {
  id: string;
  labelKey: string;
  descriptionKey?: string;
  entries: ServerPropertyEntry[];
  isOther?: boolean;
}

export interface ServerPropertyEntry {
  key: string;
  labelKey: string;
  helpKey?: string;
  type: ServerPropertyType;
  value: string | number | boolean | null;
  defaultValue?: string | number | boolean | null;
  enumValues?: string[];
  min?: number;
  max?: number;
  minecraftVersion?: string;
  isExtra?: boolean;
  hasChanged?: boolean;
}

export interface ServerPropertiesUpdateRequest {
  values: Record<string, unknown>;
}
