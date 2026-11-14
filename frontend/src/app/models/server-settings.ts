import { ModDataProvider } from './mod-data-provider';

export interface ServerSettings {
  id?: string;
  projectPath?: string;
  defaultJavaXmx?: string;
  defaultJavaXms?: string;
  modProvider?: ModDataProvider;
  curseForgeApiKey?: string;
}
