import { ChangeDetectionStrategy, Component, inject, signal } from '@angular/core';
import { NavigationEnd, Router, RouterLink } from '@angular/router';
import { filter, map } from 'rxjs';

import { MatButtonModule } from '@angular/material/button';
import { TranslateModule } from '@ngx-translate/core';

@Component({
  standalone: true,
  imports: [RouterLink, TranslateModule, MatButtonModule],
  templateUrl: './error.html',
  styleUrls: ['./error.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export default class ErrorComponent {
  private readonly router = inject(Router);
  protected readonly notFoundPath = signal('');

  constructor() {
    this.router.events
      .pipe(
        filter((event) => event instanceof NavigationEnd),
        map((event) => (event as NavigationEnd).urlAfterRedirects)
      )
      .subscribe((url) => {
        this.notFoundPath.set(url);
      });
  }
}
