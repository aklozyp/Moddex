import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TranslateLoader, TranslateModule } from '@ngx-translate/core';
import { Observable, of } from 'rxjs';

import { NewInstanceGeneralComponent } from './general';
import { NewInstanceStateService } from '../../new-instance/new-instance-state.service';
import { Instance, ModLoader } from '../../../../models/instance';
import { ServerService } from '../../../../services/server-service';

class FakeLoader extends TranslateLoader {
  getTranslation(lang: string): Observable<any> {
    return of({});
  }
}

const BASE_ORIGIN = 'http://backend.test';
const INSTANCE_ID = '11111111-2222-3333-4444-555555555555';
const INSTANCE_URL = `${BASE_ORIGIN}/api/v1/instance/${INSTANCE_ID}`;
const OTHER_INSTANCE_ID = '99999999-8888-7777-6666-555555555555';
const JAVA_VERSIONS_URL = `${BASE_ORIGIN}/api/v1/java/versions`;

const EXISTING_INSTANCE: Instance = {
  id: INSTANCE_ID,
  name: 'Existing Instance',
  description: 'Old description',
  gameVersion: '1.20.1',
  modLoader: ModLoader.VANILLA,
  modLoaderVersion: '0.15.11',
  javaXmx: '4G',
  javaXms: '2G',
  javaPath: '',
};

const OTHER_INSTANCE: Instance = {
  id: OTHER_INSTANCE_ID,
  name: 'Other Instance',
  description: 'Another instance',
  gameVersion: '1.21.4',
  modLoader: ModLoader.FABRIC,
  modLoaderVersion: '0.16.9',
  javaXmx: '8G',
  javaXms: '4G',
  javaPath: '',
};

describe('NewInstanceGeneralComponent', () => {
  let component: NewInstanceGeneralComponent;
  let fixture: ComponentFixture<NewInstanceGeneralComponent>;
  let httpMock: HttpTestingController;
  let state: NewInstanceStateService;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [
        NewInstanceGeneralComponent,
        HttpClientTestingModule,
        TranslateModule.forRoot({
          loader: { provide: TranslateLoader, useClass: FakeLoader },
        }),
      ],
      providers: [
        {
          provide: ServerService,
          useValue: { getCurrentOrigin: () => BASE_ORIGIN },
        },
      ],
    }).compileComponents();

    state = TestBed.inject(NewInstanceStateService);
    httpMock = TestBed.inject(HttpTestingController);

    state.setInstance(EXISTING_INSTANCE);

    fixture = TestBed.createComponent(NewInstanceGeneralComponent);
    component = fixture.componentInstance;

    // The component loads the Java version list on construction.
    httpMock.expectOne(JAVA_VERSIONS_URL).flush([]);

    fixture.detectChanges();
  });

  afterEach(() => {
    // Fails the test if any unexpected request (for example a create POST) was made.
    httpMock.verify();
    state.reset();
  });

  it('should create and patch the form from the loaded instance', () => {
    expect(component).toBeTruthy();
    expect(component.hasInstance()).toBeTrue();

    const value = component.form.getRawValue();
    expect(value.name).toBe('Existing Instance');
    expect(value.description).toBe('Old description');
    expect(value.gameVersion).toBe('1.20.1');
    expect(value.modLoader).toBe('Vanilla');
    expect(value.loaderVersion).toBe('0.15.11');
  });

  it('saves an update via PUT without creating a second project', () => {
    component.form.controls.name.setValue('Renamed Instance');
    component.form.controls.description.setValue('New description');
    component.form.controls.javaPath.setValue('/usr/lib/jvm/java-21');

    component.saveChanges();

    const request = httpMock.expectOne(INSTANCE_URL);
    expect(request.request.method).toBe('PUT');
    // The instance id travels in the URL path only, not in the request body.
    expect(request.request.body).toEqual({
      name: 'Renamed Instance',
      description: 'New description',
      gameVersion: '1.20.1',
      modLoader: 'VANILLA',
      modLoaderVersion: '0.15.11',
      javaXmx: '4G',
      javaXms: '2G',
      javaPath: '/usr/lib/jvm/java-21',
    });

    // The backend answers with the uppercase enum name for modLoader.
    const updated = {
      ...EXISTING_INSTANCE,
      name: 'Renamed Instance',
      description: 'New description',
      javaPath: '/usr/lib/jvm/java-21',
      modLoader: 'VANILLA',
    };
    request.flush(updated);

    expect(component.statusMessage()).toBe('NEW_INSTANCE.UPDATE_PROJECT_SUCCESS');
    expect(component.statusType()).toBe('success');
    expect(component.isSubmitting()).toBeFalse();
    expect(state.instance()?.name).toBe('Renamed Instance');

    // The state update re-patches the form through an effect that runs on change detection.
    fixture.detectChanges();
    expect(component.form.getRawValue().name).toBe('Renamed Instance');
  });

  it('preserves edits made while a save request is in flight', () => {
    component.form.controls.name.setValue('Saved Name');
    component.form.controls.description.setValue('Saved description');

    component.saveChanges();

    const request = httpMock.expectOne(INSTANCE_URL);
    expect(component.isSubmitting()).toBeTrue();

    // The user keeps typing while the request is running.
    component.form.controls.name.setValue('Edited while saving');

    // The response differs from the edited form values on purpose: a state
    // refresh for the same instance must not overwrite the form.
    request.flush({
      ...EXISTING_INSTANCE,
      name: 'Saved Name',
      description: 'Saved description',
      javaPath: '/usr/lib/jvm/java-21',
    });

    expect(component.statusMessage()).toBe('NEW_INSTANCE.UPDATE_PROJECT_SUCCESS');
    expect(component.statusType()).toBe('success');
    expect(component.isSubmitting()).toBeFalse();

    fixture.detectChanges();
    // The edit made while the request was running is not overwritten.
    expect(component.form.getRawValue().name).toBe('Edited while saving');
    // The form keeps the values as sent; a state refresh for the same instance
    // does not re-patch it.
    expect(component.form.getRawValue().description).toBe('Saved description');
    expect(component.form.getRawValue().javaPath).toBe('');
  });

  it('shows no error while the instance is loading and only reports unavailability after loading', () => {
    state.setInstance(null);
    state.setInstanceLoading(true);
    fixture.detectChanges();

    expect(component.hasInstance()).toBeFalse();
    expect(fixture.nativeElement.querySelector('.status.error')).toBeNull();

    state.setInstanceLoading(false);
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.status.error')).not.toBeNull();
    expect(component.statusMessage()).toBeNull();
  });

  it('keeps the form editable and allows a retry when the update fails', () => {
    component.form.controls.name.setValue('Updated Name');

    component.saveChanges();

    const failedRequest = httpMock.expectOne(INSTANCE_URL);
    expect(failedRequest.request.method).toBe('PUT');
    failedRequest.flush({ message: 'boom' }, { status: 500, statusText: 'Server Error' });

    expect(component.statusMessage()).toBe('NEW_INSTANCE.UPDATE_PROJECT_ERROR');
    expect(component.statusType()).toBe('error');
    expect(component.isSubmitting()).toBeFalse();
    // The entered values survive the failed request so the user can retry.
    expect(component.form.getRawValue().name).toBe('Updated Name');

    component.saveChanges();

    const retryRequest = httpMock.expectOne(INSTANCE_URL);
    expect(retryRequest.request.method).toBe('PUT');
    retryRequest.flush({ ...EXISTING_INSTANCE, name: 'Updated Name' });

    expect(component.statusMessage()).toBe('NEW_INSTANCE.UPDATE_PROJECT_SUCCESS');
    expect(component.statusType()).toBe('success');
  });

  it('rejects an empty instance name client-side without any request', () => {
    component.form.controls.name.setValue('   ');

    component.saveChanges();

    expect(component.statusMessage()).toBe('NEW_INSTANCE.NAME_REQUIRED');
    expect(component.statusType()).toBe('error');
    expect(component.isSubmitting()).toBeFalse();
  });

  it('reports an unavailable instance and does nothing when no instance is loaded', () => {
    state.setInstance(null);
    fixture.detectChanges();

    expect(component.hasInstance()).toBeFalse();

    component.saveChanges();

    expect(component.statusMessage()).toBe('NEW_INSTANCE.INSTANCE_UNAVAILABLE');
    expect(component.statusType()).toBe('error');
    expect(component.isSubmitting()).toBeFalse();
  });

  it('drops a late save response after the user switched to another instance', () => {
    component.form.controls.name.setValue('Renamed While Request Runs');

    component.saveChanges();

    const request = httpMock.expectOne(INSTANCE_URL);
    expect(request.request.method).toBe('PUT');

    // The route reuses the component; the state now holds the other instance.
    state.setInstance(OTHER_INSTANCE);
    fixture.detectChanges();

    expect(component.form.getRawValue().name).toBe('Other Instance');

    // The stale PUT response for the previous instance arrives afterwards.
    request.flush({
      ...EXISTING_INSTANCE,
      name: 'Renamed While Request Runs',
      modLoader: 'VANILLA',
    });

    // The stale response must not clobber the state or the form of the
    // instance the user is currently viewing.
    expect(state.instance()?.id).toBe(OTHER_INSTANCE_ID);
    expect(state.instance()?.name).toBe('Other Instance');
    expect(component.form.getRawValue().name).toBe('Other Instance');
    // The stale success is not reported as if it belonged to this instance.
    expect(component.statusMessage()).toBeNull();
    expect(component.isSubmitting()).toBeFalse();
  });

  it('drops a late save failure after the user switched to another instance', () => {
    component.form.controls.name.setValue('Renamed While Request Runs');

    component.saveChanges();

    const request = httpMock.expectOne(INSTANCE_URL);
    expect(request.request.method).toBe('PUT');

    state.setInstance(OTHER_INSTANCE);
    fixture.detectChanges();

    request.flush({ message: 'boom' }, { status: 500, statusText: 'Server Error' });

    // The stale failure must not report a save error on the other instance's
    // page, and the switched-to form stays untouched.
    expect(component.statusMessage()).toBeNull();
    expect(component.statusType()).toBeNull();
    expect(component.isSubmitting()).toBeFalse();
    expect(component.form.getRawValue().name).toBe('Other Instance');
  });

  it('keeps the editable fields disabled while another instance is loading', () => {
    state.setInstanceLoading(true);
    fixture.detectChanges();

    expect(component.form.controls.name.disabled).toBeTrue();
    expect(component.form.controls.description.disabled).toBeTrue();
    expect(component.form.controls.javaPath.disabled).toBeTrue();

    state.setInstance(OTHER_INSTANCE);
    state.setInstanceLoading(false);
    fixture.detectChanges();

    // Loading the instance re-enables the fields and shows its values.
    expect(component.form.controls.name.disabled).toBeFalse();
    expect(component.form.getRawValue().name).toBe('Other Instance');

    // The read-only loader fields stay disabled.
    expect(component.form.controls.gameVersion.disabled).toBeTrue();
    expect(component.form.controls.modLoader.disabled).toBeTrue();
    expect(component.form.controls.loaderVersion.disabled).toBeTrue();
  });
});
