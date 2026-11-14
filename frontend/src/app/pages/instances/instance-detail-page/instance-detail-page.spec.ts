import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { ActivatedRoute } from '@angular/router';
import { TranslateLoader, TranslateModule } from '@ngx-translate/core';
import { Observable, of } from 'rxjs';

import { InstanceDetailPage } from './instance-detail-page';

class FakeLoader extends TranslateLoader {
  getTranslation(lang: string): Observable<any> {
    return of({});
  }
}

describe('InstanceDetailPage', () => {
  let component: InstanceDetailPage;
  let fixture: ComponentFixture<InstanceDetailPage>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [
        InstanceDetailPage,
        HttpClientTestingModule,
        TranslateModule.forRoot({
          loader: { provide: TranslateLoader, useClass: FakeLoader },
        }),
      ],
      providers: [
        {
          provide: ActivatedRoute,
          useValue: {
            paramMap: of(new Map([['modId', 'test-mod-id']])),
            parent: {
              parent: {
                paramMap: of(new Map([['id', 'test-instance-id']])),
              },
            },
          },
        },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(InstanceDetailPage);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
