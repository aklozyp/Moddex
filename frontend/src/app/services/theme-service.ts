import { Injectable, effect, signal } from '@angular/core';

type McColor =
  | 'white' | 'light-gray' | 'gray' | 'black'
  | 'brown' | 'red' | 'orange' | 'yellow'
  | 'lime' | 'green' | 'cyan' | 'light-blue'
  | 'blue' | 'purple' | 'magenta' | 'pink';

export type AppTheme =
  | 'light'
  | 'dark'
  | 'hc'
  | `theme-${McColor}`;

const THEME_KEY = 'app-theme';

export const THEME_ORDER: AppTheme[] = [
  'light','dark','hc',
  'theme-white','theme-light-gray','theme-gray','theme-black',
  'theme-brown','theme-red','theme-orange','theme-yellow',
  'theme-lime','theme-green','theme-cyan','theme-light-blue',
  'theme-blue','theme-purple','theme-magenta','theme-pink'
];

@Injectable({ providedIn: 'root' })
export class ThemeService {
  private key = THEME_KEY;
  theme = signal<AppTheme>(this.load());

  constructor() {
    effect(() => {
      const t = this.theme();
      document.documentElement.setAttribute('data-theme', t);
      localStorage.setItem(this.key, t);

      // Meta Theme-Color (Mobile)
      const meta = document.querySelector('meta[name="theme-color"]');
      if (meta) {
        const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
        if (bg) meta.setAttribute('content', bg);
      }
    });
  }

  toggle() {
    const t = this.theme();
    if (t === 'dark') this.set('light');
    else this.set('dark');
  }

  cycle(direction: 1 | -1 = 1) {
    const cur = this.theme();
    const idx = THEME_ORDER.indexOf(cur);
    const next = THEME_ORDER[(idx + direction + THEME_ORDER.length) % THEME_ORDER.length];
    this.set(next);
  }

  set(t: AppTheme) { this.theme.set(t); }

  private load(): AppTheme {
    const saved = localStorage.getItem(this.key) as AppTheme | null;
    if (saved) return saved;
    const prefersDark = window.matchMedia?.('(prefers-color-scheme: dark)').matches;
    return prefersDark ? 'dark' : 'light';
  }
}

// Example Usage

/*
<button (click)="themeService.toggle()">Light/Dark</button>
<button (click)="themeService.cycle()">Next Theme</button>
<button (click)="themeService.set('mc-red')">MC Red</button>
*/

