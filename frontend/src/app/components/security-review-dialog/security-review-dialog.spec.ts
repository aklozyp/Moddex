import { ComponentFixture, TestBed } from '@angular/core/testing';
import { NoopAnimationsModule } from '@angular/platform-browser/animations';
import {
  MAT_DIALOG_DATA,
  MatDialogRef,
} from '@angular/material/dialog';
import { TranslateModule } from '@ngx-translate/core';

import {
  SecurityReviewDialogComponent,
  SecurityReviewData,
} from './security-review-dialog.component';

const buildData = (overrides: Partial<SecurityReviewData> = {}): SecurityReviewData => ({
  titleKey: 'SECURITY_REVIEW.RESTORE_TITLE',
  descriptionKey: 'SECURITY_REVIEW.RESTORE_DESCRIPTION',
  warnings: [],
  ...overrides,
});

describe('SecurityReviewDialogComponent', () => {
  let fixture: ComponentFixture<SecurityReviewDialogComponent>;
  let component: SecurityReviewDialogComponent;
  let dialogRef: jasmine.SpyObj<MatDialogRef<SecurityReviewDialogComponent>>;

  function setup(data: SecurityReviewData = buildData()) {
    dialogRef = jasmine.createSpyObj('MatDialogRef', ['close']);

    TestBed.configureTestingModule({
      imports: [
        NoopAnimationsModule,
        SecurityReviewDialogComponent,
        TranslateModule.forRoot(),
      ],
      providers: [
        { provide: MatDialogRef, useValue: dialogRef },
        { provide: MAT_DIALOG_DATA, useValue: data },
      ],
    });

    fixture = TestBed.createComponent(SecurityReviewDialogComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  }

  it('closes with true when confirm() is called', () => {
    setup();
    component.confirm();
    expect(dialogRef.close).toHaveBeenCalledWith(true);
  });

  it('closes with false when cancel() is called', () => {
    setup();
    component.cancel();
    expect(dialogRef.close).toHaveBeenCalledWith(false);
  });

  it('allows confirmation without checkbox when requireCheckbox is false', () => {
    setup(buildData({ requireCheckbox: false }));
    expect(component['canConfirm']()).toBeTrue();
  });

  it('blocks confirmation until checkbox is checked when requireCheckbox is true', () => {
    setup(buildData({ requireCheckbox: true }));
    expect(component['canConfirm']()).toBeFalse();

    component['toggleConfirm'](true);
    expect(component['canConfirm']()).toBeTrue();

    component['toggleConfirm'](false);
    expect(component['canConfirm']()).toBeFalse();
  });

  it('detects critical warnings', () => {
    setup(
      buildData({
        warnings: [
          { level: 'critical', message: 'Data loss!' },
          { level: 'warning', message: 'Check mods.' },
        ],
      }),
    );
    expect(component['hasCritical']()).toBeTrue();
  });

  it('returns false for hasCritical when no critical warnings exist', () => {
    setup(
      buildData({
        warnings: [
          { level: 'warning', message: 'Some warning' },
          { level: 'info', message: 'FYI' },
        ],
      }),
    );
    expect(component['hasCritical']()).toBeFalse();
  });

  it('renders correct icon for each warning level', () => {
    setup();
    expect(component['warningIcon']('critical')).toBe('error');
    expect(component['warningIcon']('warning')).toBe('warning');
    expect(component['warningIcon']('info')).toBe('info');
  });

  it('renders correct icon for each change type', () => {
    setup();
    expect(component['changeIcon']('add')).toBe('add_circle');
    expect(component['changeIcon']('remove')).toBe('remove_circle');
    expect(component['changeIcon']('update')).toBe('update');
    expect(component['changeIcon']('overwrite')).toBe('find_replace');
  });
});
