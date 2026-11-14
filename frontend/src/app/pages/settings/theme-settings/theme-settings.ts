import { Component, inject } from '@angular/core';
import { THEME_ORDER, AppTheme } from "../../../services/theme-service";
import { TranslatePipe } from "@ngx-translate/core";
import { CommonModule } from "@angular/common";
import { SettingsService } from "../../../services/settings-service";

@Component({
  selector: 'app-theme-settings',
  standalone: true,
  imports: [
    TranslatePipe,
    CommonModule
  ],
  templateUrl: './theme-settings.html',
  styleUrl: './theme-settings.scss'
})
export class ThemeSettingsComponent {
  themes = THEME_ORDER;
  protected settingsService = inject(SettingsService);
  readonly themeLabels: Record<AppTheme, string> = {
    light: 'THEME_NAME_LIGHT',
    dark: 'THEME_NAME_DARK',
    hc: 'THEME_NAME_HC',
    'theme-white': 'THEME_NAME_WHITE',
    'theme-light-gray': 'THEME_NAME_LIGHT_GRAY',
    'theme-gray': 'THEME_NAME_GRAY',
    'theme-black': 'THEME_NAME_BLACK',
    'theme-brown': 'THEME_NAME_BROWN',
    'theme-red': 'THEME_NAME_RED',
    'theme-orange': 'THEME_NAME_ORANGE',
    'theme-yellow': 'THEME_NAME_YELLOW',
    'theme-lime': 'THEME_NAME_LIME',
    'theme-green': 'THEME_NAME_GREEN',
    'theme-cyan': 'THEME_NAME_CYAN',
    'theme-light-blue': 'THEME_NAME_LIGHT_BLUE',
    'theme-blue': 'THEME_NAME_BLUE',
    'theme-purple': 'THEME_NAME_PURPLE',
    'theme-magenta': 'THEME_NAME_MAGENTA',
    'theme-pink': 'THEME_NAME_PINK'
  };

  setTheme(theme: AppTheme) {
    this.settingsService.updateDraft({ webTheme: theme });
  }
}
