import { Component, inject, signal } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { Navbar } from './components/navbar/navbar';
import { TranslateModule, TranslateService } from '@ngx-translate/core';
import { SettingsService } from "./services/settings-service";
import { AuthService } from "./services/auth.service";
import { SaveBarComponent } from "./components/save-bar/save-bar";
import { CommonModule } from "@angular/common";

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, Navbar, TranslateModule, SaveBarComponent, CommonModule],
  templateUrl: './app.html',
  styleUrl: './app.scss'
})
export class App {
  public readonly title = signal('Moddex-Frontend');
  protected settingsService = inject(SettingsService);
  protected authService = inject(AuthService);

  constructor(translate: TranslateService) {
    translate.setDefaultLang('en');
    translate.use('de');
    this.settingsService.loadInitialSettings();
    // Gespeichertes Token direkt beim Start serverseitig prüfen; der
    // Auth-Guard wartet auf dasselbe Ergebnis (ein einziger Request).
    this.authService.validateStoredToken().subscribe();
  }
}
