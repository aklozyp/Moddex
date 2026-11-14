import { HttpErrorResponse } from '@angular/common/http';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ActivatedRoute, convertToParamMap } from '@angular/router';
import { TranslateLoader, TranslateModule, TranslateService } from '@ngx-translate/core';
import { firstValueFrom, Observable, of, throwError } from 'rxjs';

import { ApiService } from '../../../../services/api-service';
import { ConsoleComponent } from './console.component';

const INSTANCE_ID = 'test-instance-id';
const GERMAN_EULA_PROMPT =
  'Du musst die Minecraft-EULA akzeptieren, bevor dieser Server gestartet werden kann. Möchtest du sie akzeptieren und den Server starten?';

class ConsoleTestLoader extends TranslateLoader {
  getTranslation(_lang: string): Observable<any> {
    return of({ CONSOLE: { EULA_REQUIRED: GERMAN_EULA_PROMPT } });
  }
}

describe('ConsoleComponent', () => {
  let component: ConsoleComponent;
  let fixture: ComponentFixture<ConsoleComponent>;
  let apiService: jasmine.SpyObj<ApiService>;

  beforeEach(async () => {
    apiService = jasmine.createSpyObj<ApiService>('ApiService', [
      'startInstance',
      'acceptEula',
      'getInstanceLogs',
      'getInstanceStatus'
    ]);
    apiService.startInstance.and.returnValue(of({}));
    apiService.acceptEula.and.returnValue(of({}));
    apiService.getInstanceLogs.and.returnValue(of([]));
    apiService.getInstanceStatus.and.returnValue(of({ status: 'STOPPED' }));

    await TestBed.configureTestingModule({
      imports: [
        ConsoleComponent,
        TranslateModule.forRoot({
          loader: { provide: TranslateLoader, useClass: ConsoleTestLoader }
        })
      ],
      providers: [
        { provide: ApiService, useValue: apiService },
        {
          provide: ActivatedRoute,
          useValue: { parent: { paramMap: of(convertToParamMap({ id: INSTANCE_ID })) } }
        }
      ]
    }).compileComponents();

    await firstValueFrom(TestBed.inject(TranslateService).use('de'));
    fixture = TestBed.createComponent(ConsoleComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  afterEach(() => fixture.destroy());

  it('opens the localized EULA flow based on errorKind, regardless of backend message', () => {
    apiService.startInstance.and.returnValues(
      throwError(
        () =>
          new HttpErrorResponse({
            status: 400,
            error: {
              error: 'Die Vereinbarung muss zuerst angenommen werden',
              errorKind: 'EULA_NOT_ACCEPTED'
            }
          })
      ),
      of({ message: 'Started' })
    );
    const confirmSpy = spyOn(window, 'confirm').and.returnValue(true);

    component.start();

    expect(confirmSpy).toHaveBeenCalledOnceWith(GERMAN_EULA_PROMPT);
    expect(apiService.acceptEula).toHaveBeenCalledOnceWith(INSTANCE_ID);
    expect(apiService.startInstance).toHaveBeenCalledTimes(2);
  });

  it('does not accept the EULA or retry when the user declines', () => {
    apiService.startInstance.and.returnValue(
      throwError(
        () => new HttpErrorResponse({ status: 400, error: { errorKind: 'EULA_NOT_ACCEPTED' } })
      )
    );
    spyOn(window, 'confirm').and.returnValue(false);

    component.start();

    expect(apiService.acceptEula).not.toHaveBeenCalled();
    expect(apiService.startInstance).toHaveBeenCalledTimes(1);
  });

  it('keeps unrelated errors out of the EULA flow', () => {
    apiService.startInstance.and.returnValue(
      throwError(
        () => new HttpErrorResponse({ status: 500, error: { error: 'Filesystem unavailable' } })
      )
    );
    const confirmSpy = spyOn(window, 'confirm');
    const consoleErrorSpy = spyOn(console, 'error');

    component.start();

    expect(confirmSpy).not.toHaveBeenCalled();
    expect(apiService.acceptEula).not.toHaveBeenCalled();
    expect(consoleErrorSpy).toHaveBeenCalledOnceWith('Failed to start instance');
  });
});
