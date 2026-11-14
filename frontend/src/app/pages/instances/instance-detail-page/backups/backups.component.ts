import { Component, DestroyRef, inject, OnInit, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ApiService } from '../../../../services/api-service';
import { ActivatedRoute } from '@angular/router';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatTableModule } from '@angular/material/table';
import { MatDialog } from '@angular/material/dialog';
import { MatSnackBar, MatSnackBarModule } from '@angular/material/snack-bar';
import { MatTooltipModule } from '@angular/material/tooltip';
import { TranslateModule, TranslateService } from '@ngx-translate/core';
import { finalize, firstValueFrom } from 'rxjs';
import {
  SecurityReviewDialogComponent,
  SecurityReviewData,
} from '../../../../components/security-review-dialog/security-review-dialog.component';

interface BackupEntry {
  name: string;
  size: number;
  timestamp: number;
}

@Component({
  selector: 'app-instance-backups',
  standalone: true,
  imports: [
    CommonModule,
    MatButtonModule,
    MatIconModule,
    MatTableModule,
    MatSnackBarModule,
    MatTooltipModule,
    TranslateModule,
  ],
  templateUrl: './backups.component.html',
  styleUrl: './backups.component.scss',
})
export class BackupsComponent implements OnInit {
  private readonly api = inject(ApiService);
  private readonly route = inject(ActivatedRoute);
  private readonly destroyRef = inject(DestroyRef);
  private readonly dialog = inject(MatDialog);
  private readonly snackBar = inject(MatSnackBar);
  private readonly translate = inject(TranslateService);

  readonly instanceId = signal<string | null>(null);
  readonly backups = signal<BackupEntry[]>([]);
  readonly isLoading = signal<boolean>(false);
  readonly isCreating = signal<boolean>(false);
  readonly restoringName = signal<string | null>(null);

  readonly displayedColumns = ['name', 'date', 'size', 'actions'];

  ngOnInit() {
    this.route.parent?.paramMap
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(params => {
        const id = params.get('id');
        if (id) {
          this.instanceId.set(id);
          this.loadBackups();
        }
      });
  }

  loadBackups() {
    const id = this.instanceId();
    if (!id) return;

    this.isLoading.set(true);
    this.api
      .listBackups(id)
      .pipe(finalize(() => this.isLoading.set(false)))
      .subscribe({
        next: data => this.backups.set(data),
        error: () =>
          this.snackBar.open(
            this.translate.instant('BACKUPS.LOAD_ERROR'),
            undefined,
            { duration: 4000 },
          ),
      });
  }

  createBackup() {
    const id = this.instanceId();
    if (!id || this.isCreating()) return;

    this.isCreating.set(true);
    this.api
      .createBackup(id)
      .pipe(finalize(() => this.isCreating.set(false)))
      .subscribe({
        next: () => {
          this.snackBar.open(
            this.translate.instant('BACKUPS.CREATE_SUCCESS'),
            undefined,
            { duration: 3000 },
          );
          this.loadBackups();
        },
        error: () =>
          this.snackBar.open(
            this.translate.instant('BACKUPS.CREATE_ERROR'),
            undefined,
            { duration: 4000 },
          ),
      });
  }

  deleteBackup(name: string) {
    if (!confirm(this.translate.instant('BACKUPS.DELETE_CONFIRM'))) return;

    const id = this.instanceId();
    if (!id) return;

    this.api.deleteBackup(id, name).subscribe({
      next: () => {
        this.snackBar.open(
          this.translate.instant('BACKUPS.DELETE_SUCCESS'),
          undefined,
          { duration: 3000 },
        );
        this.loadBackups();
      },
      error: () =>
        this.snackBar.open(
          this.translate.instant('BACKUPS.DELETE_ERROR'),
          undefined,
          { duration: 4000 },
        ),
    });
  }

  async restoreBackup(entry: BackupEntry) {
    const id = this.instanceId();
    if (!id || this.restoringName()) return;

    const reviewData: SecurityReviewData = {
      titleKey: 'SECURITY_REVIEW.RESTORE_TITLE',
      descriptionKey: 'SECURITY_REVIEW.RESTORE_DESCRIPTION',
      descriptionParams: { name: entry.name },
      warnings: [
        {
          level: 'critical',
          message: this.translate.instant('SECURITY_REVIEW.RESTORE_WARN_OVERWRITE'),
        },
        {
          level: 'warning',
          message: this.translate.instant('SECURITY_REVIEW.RESTORE_WARN_MODS'),
        },
        {
          level: 'info',
          message: this.translate.instant('SECURITY_REVIEW.RESTORE_INFO_BACKUP_DATE', {
            date: new Date(entry.timestamp).toLocaleString(),
            size: this.formatBytes(entry.size),
          }),
        },
      ],
      requireCheckbox: true,
      confirmLabelKey: 'SECURITY_REVIEW.RESTORE_CONFIRM_LABEL',
    };

    const confirmed = await firstValueFrom(
      this.dialog
        .open(SecurityReviewDialogComponent, { data: reviewData, maxWidth: '600px' })
        .afterClosed(),
    );

    if (!confirmed) return;

    this.restoringName.set(entry.name);
    this.api
      .restoreBackup(id, entry.name)
      .pipe(finalize(() => this.restoringName.set(null)))
      .subscribe({
        next: () =>
          this.snackBar.open(
            this.translate.instant('BACKUPS.RESTORE_SUCCESS'),
            undefined,
            { duration: 4000 },
          ),
        error: (err: unknown) => {
          const detail =
            err instanceof Error ? err.message : this.translate.instant('BACKUPS.RESTORE_ERROR');
          this.snackBar.open(detail, undefined, { duration: 6000 });
        },
      });
  }

  formatBytes(bytes: number, decimals = 2): string {
    if (!+bytes) return '0 Bytes';
    const k = 1024;
    const dm = decimals < 0 ? 0 : decimals;
    const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return `${parseFloat((bytes / Math.pow(k, i)).toFixed(dm))} ${sizes[i]}`;
  }
}
