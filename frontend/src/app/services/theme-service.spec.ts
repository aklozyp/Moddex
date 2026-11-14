import { TestBed, fakeAsync, tick } from '@angular/core/testing';

import { ThemeService } from './theme-service';

const originalMatchMedia = window.matchMedia;

function stubMatchMedia(matches: boolean): MediaQueryList {
  return {
    matches,
    media: '',
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  } as MediaQueryList;
}

describe('ThemeService', () => {
  beforeEach(() => {
    localStorage.clear();
    Object.defineProperty(window, 'matchMedia', {
      writable: true,
      value: jasmine.createSpy('matchMedia').and.returnValue(stubMatchMedia(false)),
    });
    document.documentElement.removeAttribute('data-theme');
    TestBed.configureTestingModule({
      providers: [ThemeService],
    });
  });

  afterEach(() => {
    Object.defineProperty(window, 'matchMedia', { writable: true, value: originalMatchMedia });
    TestBed.resetTestingModule();
  });

  it('toggle switches between light and dark themes', fakeAsync(() => {
    const service = TestBed.inject(ThemeService);
    service.set('light');
    tick();

    service.toggle();
    tick();
    expect(service.theme()).toBe('dark');
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark');

    service.toggle();
    tick();
    expect(service.theme()).toBe('light');
    expect(document.documentElement.getAttribute('data-theme')).toBe('light');
  }));

  it('cycle advances and reverses the theme order', fakeAsync(() => {
    const service = TestBed.inject(ThemeService);

    service.set('theme-red');
    tick();

    service.cycle(1);
    tick();
    expect(service.theme()).toBe('theme-orange');

    service.cycle(-1);
    tick();
    expect(service.theme()).toBe('theme-red');
  }));

  it('initializes from stored theme when available', fakeAsync(() => {
    localStorage.setItem('app-theme', 'theme-purple');
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      providers: [ThemeService],
    });

    const service = TestBed.inject(ThemeService);
    tick(); // Allow effect to run

    expect(service.theme()).toBe('theme-purple');
    expect(document.documentElement.getAttribute('data-theme')).toBe('theme-purple');
  }));
});