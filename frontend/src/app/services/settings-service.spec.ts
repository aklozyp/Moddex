import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';

import { SettingsService } from './settings-service';
import { ThemeService } from './theme-service';
import { ServerService } from './server-service';

const SERVER_ORIGIN = 'http://backend.test:8080';
const SETTINGS_ENDPOINT = SERVER_ORIGIN + '/api/client/settings';

describe('SettingsService', () => {
  let service: SettingsService;
  let httpMock: HttpTestingController;
  let themeService: jasmine.SpyObj<ThemeService>;

  beforeEach(() => {
    themeService = jasmine.createSpyObj<ThemeService>('ThemeService', ['set']);

    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        SettingsService,
        { provide: ThemeService, useValue: themeService },
        {
          provide: ServerService,
          useValue: { getCurrentOrigin: () => SERVER_ORIGIN },
        },
      ],
    });

    service = TestBed.inject(SettingsService);
    httpMock = TestBed.inject(HttpTestingController);
    localStorage.clear();
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('loads settings from the server and updates theme', async () => {
    const loadPromise = service.loadInitialSettings();
    const request = httpMock.expectOne(SETTINGS_ENDPOINT);
    request.flush({ webTheme: 'dark' });
    await loadPromise;

    TestBed.flushEffects();

    expect(service.settings$()?.webTheme).toBe('dark');
    expect(service.draftSettings$()?.webTheme).toBe('dark');
    expect(themeService.set).toHaveBeenCalledWith('dark');
    expect(localStorage.getItem('moddex.settings')).toContain('"dark"');
  });

  it('falls back to local storage when server request fails', async () => {
    localStorage.setItem('moddex.settings', JSON.stringify({ webTheme: 'hc' }));

    const loadPromise = service.loadInitialSettings();
    const request = httpMock.expectOne(SETTINGS_ENDPOINT);
    request.error(new ProgressEvent('error'));
    await loadPromise;

    TestBed.flushEffects();

    expect(service.settings$()?.webTheme).toBe('hc');
    expect(service.draftSettings$()?.webTheme).toBe('hc');
    expect(themeService.set).toHaveBeenCalledWith('hc');
  });

  it('persists draft settings to the server and resets dirty state', async () => {
    const loadPromise = service.loadInitialSettings();
    const getRequest = httpMock.expectOne(SETTINGS_ENDPOINT);
    getRequest.flush({ webTheme: 'dark' });
    await loadPromise;

    TestBed.flushEffects();
    themeService.set.calls.reset();

    service.updateDraft({ webTheme: 'light' });
    TestBed.flushEffects();

    expect(service.isDirty()).toBeTrue();
    expect(themeService.set).toHaveBeenCalledWith('light');

    const savePromise = service.save();
    const postRequest = httpMock.expectOne(SETTINGS_ENDPOINT);
    postRequest.flush({ webTheme: 'light' });
    await savePromise;

    TestBed.flushEffects();

    expect(service.settings$()?.webTheme).toBe('light');
    expect(service.draftSettings$()?.webTheme).toBe('light');
    expect(service.isDirty()).toBeFalse();
    expect(localStorage.getItem('moddex.settings')).toContain('"light"');
  });
});
