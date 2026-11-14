import {
  ChangeDetectionStrategy,
  Component,
  computed,
  inject,
  signal,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import {
  MAT_DIALOG_DATA,
  MatDialogModule,
  MatDialogRef,
} from '@angular/material/dialog';
import { MatIconModule } from '@angular/material/icon';
import { TranslatePipe } from '@ngx-translate/core';

export type WarningLevel = 'critical' | 'warning' | 'info';

export interface SecurityWarning {
  level: WarningLevel;
  message: string;
}

export interface ChangeItem {
  type: 'add' | 'remove' | 'update' | 'overwrite';
  label: string;
}

export interface SecurityReviewData {
  titleKey: string;
  descriptionKey: string;
  descriptionParams?: Record<string, unknown>;
  warnings: SecurityWarning[];
  changes?: ChangeItem[];
  requireCheckbox?: boolean;
  confirmLabelKey?: string;
}

@Component({
  selector: 'app-security-review-dialog',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatButtonModule,
    MatCheckboxModule,
    MatDialogModule,
    MatIconModule,
    TranslatePipe,
  ],
  templateUrl: './security-review-dialog.component.html',
  styleUrl: './security-review-dialog.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class SecurityReviewDialogComponent {
  protected readonly dialogRef = inject(MatDialogRef<SecurityReviewDialogComponent>);
  protected readonly data = inject<SecurityReviewData>(MAT_DIALOG_DATA);

  protected readonly confirmed = signal(false);

  protected readonly canConfirm = computed(
    () => !this.data.requireCheckbox || this.confirmed(),
  );

  protected readonly hasCritical = computed(() =>
    this.data.warnings.some(w => w.level === 'critical'),
  );

  protected warningIcon(level: WarningLevel): string {
    if (level === 'critical') return 'error';
    if (level === 'warning') return 'warning';
    return 'info';
  }

  protected changeIcon(type: ChangeItem['type']): string {
    if (type === 'add') return 'add_circle';
    if (type === 'remove') return 'remove_circle';
    if (type === 'update') return 'update';
    return 'find_replace';
  }

  protected toggleConfirm(checked: boolean): void {
    this.confirmed.set(checked);
  }

  confirm(): void {
    this.dialogRef.close(true);
  }

  cancel(): void {
    this.dialogRef.close(false);
  }
}
