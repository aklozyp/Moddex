import { AppTheme } from '../services/theme-service';

export interface ClientSettings {
  id?: string | null;
  webTheme: AppTheme;
}
