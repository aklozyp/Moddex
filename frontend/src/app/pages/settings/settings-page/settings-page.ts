import { Component, HostListener, inject, signal } from '@angular/core';
import { TranslatePipe } from '@ngx-translate/core';
import { RouterModule } from '@angular/router';
import { SettingsService } from '../../../services/settings-service';
import { Sidebar, SidebarNavigationItem } from "../../../components/sidebar/sidebar";

@Component({
  selector: 'app-settings-page',
  standalone: true,
  imports: [RouterModule, Sidebar],
  templateUrl: './settings-page.html',
  styleUrl: './settings-page.scss',
})
export class SettingsPage {
  private readonly settingsService = inject(SettingsService);

  public readonly navigationItems = signal<SidebarNavigationItem[]>([
    { label: 'GENERAL', path: 'general' },
    { label: 'THEMES', path: 'themes' },
  ]);

  @HostListener('window:beforeunload', ['$event'])
  handleBeforeUnload(event: BeforeUnloadEvent) {
    if (this.settingsService.isDirty()) {
      event.preventDefault();
      event.returnValue = '';
    }
  }

  @HostListener('window:unload')
  handleUnload() {
    if (this.settingsService.isDirty()) {
      this.settingsService.discard();
    }
  }
}
