import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { Router } from '@angular/router';
import { TranslateLoader, TranslateModule, TranslateService } from '@ngx-translate/core';
import { Observable, of } from 'rxjs';

import { NewInstance } from './new-instance';
import { NewInstanceStateService } from './new-instance-state.service';
import { ServerService } from '../../../services/server-service';

// The field error texts and the loader fetch failure message mirror the
// creation catalog; the specs assert them rendered so the i18n wiring of the
// accessible messages is checked.
const DE_FIELD_ERRORS = {
  PROJECT_NAME_REQUIRED: 'Der Projektname darf nicht leer sein. Bitte einen Namen eingeben, um das Projekt zu erstellen.',
  MINECRAFT_VERSION_REQUIRED: 'Bitte eine Minecraft-Version auswählen, um das Projekt zu erstellen.',
  LOADER_VERSION_REQUIRED: 'Für den gewählten Mod-Loader ist eine Loader-Version erforderlich. Bitte eine Version auswählen, um das Projekt zu erstellen.',
  LOADERS_LOAD_ERROR: 'Kompatible Mod-Loader konnten nicht geladen werden. Bitte die Minecraft-Version erneut auswählen, um es erneut zu versuchen, oder ohne Mod-Loader (Vanilla) fortfahren.',
};

class FakeLoader extends TranslateLoader {
  getTranslation(lang: string): Observable<any> {
    return of({ NEW_INSTANCE: DE_FIELD_ERRORS });
  }
}

const BASE_ORIGIN = 'http://backend.test';
const MINECRAFT_VERSIONS_URL = `${BASE_ORIGIN}/api/v1/version/minecraft/versions`;
const COMPATIBLE_LOADERS_URL = `${BASE_ORIGIN}/api/v1/version/modloaders/compatible/1.21.4`;
// A second Minecraft version whose loader request answers later than the
// current selection's request, to reproduce the stale response race.
const STALE_VERSION_LOADERS_URL = `${BASE_ORIGIN}/api/v1/version/modloaders/compatible/1.21.3`;
// The creation contract: the frontend posts to the bootstrap endpoint and
// consumes exactly this response form (instance + initial server properties).
const CREATE_URL = `${BASE_ORIGIN}/api/v1/instance/bootstrap`;
const INSTANCE_ID = '11111111-2222-3333-4444-555555555555';

const BOOTSTRAP_RESPONSE = {
  instance: {
    id: INSTANCE_ID,
    name: 'New Project',
    description: null,
    gameVersion: '1.21.4',
    modLoader: 'VANILLA',
    modLoaderVersion: null,
    javaXmx: '4G',
    javaXms: '2G',
    javaPath: null,
  },
  serverProperties: { categories: [] },
};

describe('NewInstance', () => {
  let component: NewInstance;
  let fixture: ComponentFixture<NewInstance>;
  let httpMock: HttpTestingController;
  let router: jasmine.SpyObj<Router>;
  let state: NewInstanceStateService;

  beforeEach(async () => {
    router = jasmine.createSpyObj<Router>('Router', ['navigate']);
    await TestBed.configureTestingModule({
      imports: [
        NewInstance,
        HttpClientTestingModule,
        TranslateModule.forRoot({
          loader: { provide: TranslateLoader, useClass: FakeLoader },
        }),
      ],
      providers: [
        { provide: Router, useValue: router },
        { provide: ServerService, useValue: { getCurrentOrigin: () => BASE_ORIGIN } },
      ],
    }).compileComponents();

    httpMock = TestBed.inject(HttpTestingController);
    state = TestBed.inject(NewInstanceStateService);
    fixture = TestBed.createComponent(NewInstance);
    component = fixture.componentInstance;

    // The component loads the Minecraft version list on construction.
    httpMock.expectOne(MINECRAFT_VERSIONS_URL).flush(['1.21.4', '1.21.3']);

    fixture.detectChanges();
  });

  afterEach(() => {
    httpMock.verify();
  });

  function submitButton(): HTMLButtonElement {
    return fixture.nativeElement.querySelector('button');
  }

  function renderedFieldErrors(): string[] {
    return Array.from(
      fixture.nativeElement.querySelectorAll('mat-error'),
      (element: HTMLElement) => (element.textContent ?? '').trim(),
    );
  }

  // Choosing a Minecraft version makes the assistant fetch the compatible
  // loaders; the effect flushes on the next change detection run.
  function flushCompatibleLoaders(loaders: { loader: string; versions: string[] }[] = []): void {
    httpMock.expectOne(COMPATIBLE_LOADERS_URL).flush(loaders);
  }

  function fillValidForm(): void {
    component.form.controls.name.setValue('New Project');
    component.form.controls.minecraftVersion.setValue('1.21.4');
  }

  it('starts the assistant from a clean state despite leftovers from another page', () => {
    // A visit to an existing instance left the shared root state filled; the
    // assistant must not inherit it, or the create button would stay disabled.
    state.setBootstrapResponse({
      instance: { id: INSTANCE_ID, name: 'Existing Instance', gameVersion: '1.21.4' },
      serverProperties: { categories: [] },
    });
    expect(state.isProjectCreated()).toBeTrue();

    fixture = TestBed.createComponent(NewInstance);
    component = fixture.componentInstance;
    httpMock.expectOne(MINECRAFT_VERSIONS_URL).flush(['1.21.4']);
    fixture.detectChanges();

    expect(state.isProjectCreated()).toBeFalse();
    expect(state.instance()).toBeNull();
    expect(state.serverProperties()).toBeNull();
    expect(component.form.getRawValue().name).toBe('');
  });

  it('starts empty again on the next visit after a completed creation', () => {
    // First visit: create successfully; the state now holds the new instance.
    fillValidForm();
    flushCompatibleLoaders();
    component.createProject();
    httpMock.expectOne(CREATE_URL).flush(BOOTSTRAP_RESPONSE);
    expect(state.isProjectCreated()).toBeTrue();
    fixture.destroy();

    // Second visit: a fresh assistant must start from a clean state, not with
    // the previously created instance pre-filled or creation disabled.
    fixture = TestBed.createComponent(NewInstance);
    component = fixture.componentInstance;
    httpMock.expectOne(MINECRAFT_VERSIONS_URL).flush(['1.21.4']);
    fixture.detectChanges();

    expect(state.isProjectCreated()).toBeFalse();
    expect(state.instance()).toBeNull();
    expect(state.serverProperties()).toBeNull();
    expect(component.form.getRawValue().name).toBe('');
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('keeps creation locked until the required fields form a valid combination', () => {
    // A fresh form may not submit: the request would carry undefined fields
    // that the backend has to reject or fill with fallbacks.
    expect(component.canSubmit()).toBeFalse();
    expect(submitButton().disabled).toBeTrue();

    component.createProject();
    httpMock.expectNone(CREATE_URL);
    expect(component.isSubmitting()).toBeFalse();

    // Only a name is still not a valid combination.
    component.form.controls.name.setValue('New Project');
    fixture.detectChanges();
    expect(component.canSubmit()).toBeFalse();
    expect(submitButton().disabled).toBeTrue();
    component.createProject();
    httpMock.expectNone(CREATE_URL);

    // The smallest valid combination unlocks the submit.
    component.form.controls.minecraftVersion.setValue('1.21.4');
    fixture.detectChanges();
    flushCompatibleLoaders();
    expect(component.canSubmit()).toBeTrue();
    expect(submitButton().disabled).toBeFalse();
  });

  it('treats a whitespace-only name as empty and keeps creation locked', () => {
    // No change detection here: the assertions target control state only.
    // The loaders fetch starts with the version change itself, so its request
    // is flushed to keep the pending-request verification honest.
    component.form.controls.name.setValue('   ');
    component.form.controls.minecraftVersion.setValue('1.21.4');
    flushCompatibleLoaders();

    expect(component.form.controls.name.hasError('required')).toBeTrue();
    expect(component.canSubmit()).toBeFalse();

    component.createProject();
    httpMock.expectNone(CREATE_URL);
    expect(component.isSubmitting()).toBeFalse();
  });

  it('requires a loader version for a non-vanilla loader and sends it in the create request', () => {
    fillValidForm();
    fixture.detectChanges();
    flushCompatibleLoaders([{ loader: 'fabric', versions: ['0.16.9'] }]);

    // The backend rejects a non-vanilla loader without a loader version with
    // HTTP 400, so the assistant must not submit that combination either.
    component.form.controls.modLoader.setValue('Fabric');
    fixture.detectChanges();
    expect(component.form.controls.loaderVersion.value).toBe('');
    expect(component.form.controls.loaderVersion.hasError('required')).toBeTrue();
    expect(component.canSubmit()).toBeFalse();

    component.createProject();
    httpMock.expectNone(CREATE_URL);

    // With the loader version chosen the combination is valid and the request
    // maps the loader to the backend contract.
    component.form.controls.loaderVersion.setValue('0.16.9');
    fixture.detectChanges();
    expect(component.canSubmit()).toBeTrue();

    component.createProject();
    const request = httpMock.expectOne(CREATE_URL);
    expect(request.request.method).toBe('POST');
    expect(request.request.body).toEqual({
      name: 'New Project',
      description: undefined,
      gameVersion: '1.21.4',
      modLoader: 'FABRIC',
      modLoaderVersion: '0.16.9',
    });
    request.flush(BOOTSTRAP_RESPONSE);
    expect(router.navigate).toHaveBeenCalledWith(['/instance', INSTANCE_ID]);
  });

  it('keeps a vanilla creation valid without a loader version', () => {
    fillValidForm();
    fixture.detectChanges();
    flushCompatibleLoaders([{ loader: 'fabric', versions: ['0.16.9'] }]);

    component.form.controls.modLoader.setValue('Fabric');
    fixture.detectChanges();
    component.form.controls.loaderVersion.setValue('0.16.9');
    fixture.detectChanges();
    expect(component.canSubmit()).toBeTrue();

    // A missing loader falls back to vanilla server-side, which needs no
    // loader version: switching back clears the requirement together with the
    // previously chosen version and keeps the submit unlocked.
    component.form.controls.modLoader.setValue('Vanilla');
    fixture.detectChanges();
    expect(component.form.controls.loaderVersion.value).toBe('');
    expect(component.form.controls.loaderVersion.hasError('required')).toBeFalse();
    expect(component.canSubmit()).toBeTrue();
    expect(submitButton().disabled).toBeFalse();
  });

  it('discards a stale loader response that arrives after the version changed', () => {
    // The user first picks 1.21.3; its loader request is slow and still in
    // flight when the selection moves on to 1.21.4.
    component.form.controls.minecraftVersion.setValue('1.21.3');
    const staleRequest = httpMock.expectOne(STALE_VERSION_LOADERS_URL);

    // The switch cancels the pending request of the previous version at the
    // transport level, so its late response can never be applied.
    component.form.controls.minecraftVersion.setValue('1.21.4');
    expect(staleRequest.cancelled).toBeTrue();

    // The newer request answers first: only 1.21.4's loaders are applied, and
    // the switch invalidates the loader choice of the previous version.
    httpMock.expectOne(COMPATIBLE_LOADERS_URL).flush([{ loader: 'forge', versions: ['47.2.0'] }]);
    expect(component.form.controls.modLoader.value).toBe('');
    expect(component.modLoaders()).toEqual(['Vanilla', 'Forge']);

    // Now the stale response for 1.21.3 "arrives" late: the mock refuses to
    // deliver it because the component cancelled the request, so the loader
    // list of the current selection cannot be overwritten.
    expect(() => staleRequest.flush([{ loader: 'fabric', versions: ['0.16.9'] }])).toThrowError();

    expect(component.modLoaders()).toEqual(['Vanilla', 'Forge']);
    expect(component.modLoaders()).not.toContain('Fabric');

    // A loader of the current version resolves its versions from the applied
    // list, proving only the current version's response is in use.
    component.form.controls.modLoader.setValue('Forge');
    expect(component.loaderVersions()).toEqual(['47.2.0']);
  });

  it('reports a failed loader fetch with a safe next action and clears it on retry', () => {
    const translate = TestBed.inject(TranslateService);
    translate.use('de').subscribe();

    fillValidForm();
    httpMock.expectOne(COMPATIBLE_LOADERS_URL)
      .flush({ message: 'Internal failure' }, { status: 500, statusText: 'Server Error' });

    // The failed fetch is a defined state, not a silent empty list: a fixed,
    // translated message names the safe next action and reveals none of the
    // failure internals, while vanilla stays selectable.
    expect(component.loadersFailed()).toBeTrue();
    expect(component.modLoaders()).toEqual(['Vanilla']);
    fixture.detectChanges();
    const loadersError = fixture.nativeElement.querySelector('.loaders-error');
    expect(loadersError.textContent.trim()).toBe(DE_FIELD_ERRORS.LOADERS_LOAD_ERROR);
    expect(loadersError.textContent).not.toContain('Internal failure');

    // Re-selecting a Minecraft version retries the fetch and leaves neither
    // the error message nor an unclear load state behind.
    component.form.controls.minecraftVersion.setValue('1.21.3');
    httpMock.expectOne(STALE_VERSION_LOADERS_URL).flush([{ loader: 'fabric', versions: ['0.16.9'] }]);

    expect(component.loadersFailed()).toBeFalse();
    expect(component.modLoaders()).toEqual(['Vanilla', 'Fabric']);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('.loaders-error')).toBeNull();
  });

  it('renders translated field errors that name the safe next action', () => {
    const translate = TestBed.inject(TranslateService);
    translate.use('de').subscribe();
    fixture.detectChanges();

    // The fresh form is invalid; the visible messages name the next action
    // instead of leaking request internals.
    expect(renderedFieldErrors()).toEqual(jasmine.arrayContaining([
      DE_FIELD_ERRORS.PROJECT_NAME_REQUIRED,
      DE_FIELD_ERRORS.MINECRAFT_VERSION_REQUIRED,
    ]));

    // The name input is programmatically tied to its rendered error message.
    const nameInput = fixture.nativeElement.querySelector('input');
    expect(nameInput.getAttribute('aria-describedby')).toContain('mat-mdc-error-');

    // Choosing a loader without a version adds its message.
    fillValidForm();
    fixture.detectChanges();
    flushCompatibleLoaders([{ loader: 'fabric', versions: ['0.16.9'] }]);
    component.form.controls.modLoader.setValue('Fabric');
    fixture.detectChanges();
    fixture.detectChanges();
    expect(renderedFieldErrors()).toContain(DE_FIELD_ERRORS.LOADER_VERSION_REQUIRED);

    // A complete combination clears every field error again.
    component.form.controls.loaderVersion.setValue('0.16.9');
    fixture.detectChanges();
    expect(renderedFieldErrors()).toEqual([]);
  });

  it('consumes the exact bootstrap response form and opens the created instance', () => {
    fillValidForm();
    flushCompatibleLoaders();
    component.createProject();

    const request = httpMock.expectOne(CREATE_URL);
    expect(request.request.method).toBe('POST');
    expect(request.request.body).toEqual({
      name: 'New Project',
      description: undefined,
      gameVersion: '1.21.4',
      modLoader: undefined,
      modLoaderVersion: undefined,
    });

    request.flush(BOOTSTRAP_RESPONSE);

    // The valid instance id lands in the state and the assistant navigates on.
    expect(state.instance()?.id).toBe(INSTANCE_ID);
    expect(state.isProjectCreated()).toBeTrue();
    expect(state.serverProperties()).toEqual({ categories: [] });
    expect(component.statusMessage()).toBe('NEW_INSTANCE.CREATE_PROJECT_SUCCESS');
    expect(router.navigate).toHaveBeenCalledWith(['/instance', INSTANCE_ID]);
    expect(component.isSubmitting()).toBeFalse();
  });

  it('reports a failed creation without navigating or setting an instance', () => {
    fillValidForm();
    flushCompatibleLoaders();
    component.createProject();

    httpMock.expectOne(CREATE_URL).flush({ message: 'boom' }, { status: 500, statusText: 'Server Error' });

    expect(state.instance()).toBeNull();
    expect(state.isProjectCreated()).toBeFalse();
    expect(component.statusMessage()).toBe('NEW_INSTANCE.CREATE_PROJECT_ERROR');
    expect(component.statusType()).toBe('error');
    expect(router.navigate).not.toHaveBeenCalled();
  });

  it('does not send a second create request after a successful creation', () => {
    fillValidForm();
    flushCompatibleLoaders();
    component.createProject();
    httpMock.expectOne(CREATE_URL).flush(BOOTSTRAP_RESPONSE);

    component.createProject();

    httpMock.expectNone(CREATE_URL);
    expect(router.navigate).toHaveBeenCalledTimes(1);
  });
});
