import { Component, DestroyRef, ElementRef, inject, OnInit, signal, ViewChild, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ApiService } from '../../../../services/api-service';
import { ActivatedRoute } from '@angular/router';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { interval, switchMap } from 'rxjs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatFormFieldModule } from '@angular/material/form-field';
import { TranslateModule, TranslateService } from '@ngx-translate/core';

const EULA_NOT_ACCEPTED_ERROR_KIND = 'EULA_NOT_ACCEPTED';

@Component({
  selector: 'app-instance-console',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatButtonModule,
    MatIconModule,
    MatInputModule,
    MatFormFieldModule,
    TranslateModule
  ],
  templateUrl: './console.component.html',
  styleUrl: './console.component.scss'
})
export class ConsoleComponent implements OnInit {
  private api = inject(ApiService);
  private translate = inject(TranslateService);
  private route = inject(ActivatedRoute);
  private destroyRef = inject(DestroyRef);

  instanceId = signal<string | null>(null);
  logs = signal<string[]>([]);
  status = signal<string>('STOPPED');
  commandInput = signal<string>('');
  autoScroll = signal<boolean>(true);

  @ViewChild('logContainer') logContainer!: ElementRef;

  constructor() {
    effect(() => {
        if (this.autoScroll() && this.logContainer) {
            this.scrollToBottom();
        }
    });
  }

  ngOnInit() {
    this.route.parent?.paramMap
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(params => {
        const id = params.get('id');
        if (id) {
          this.instanceId.set(id);
          this.startPolling(id);
        }
      });
  }

  startPolling(id: string) {
    // Poll logs every 2 seconds
    interval(2000)
      .pipe(
        takeUntilDestroyed(this.destroyRef),
        switchMap(() => this.api.getInstanceLogs(id))
      )
      .subscribe({
        next: (lines) => {
            const currentLen = this.logs().length;
            if (lines.length !== currentLen) {
                 this.logs.set(lines);
                 if (this.autoScroll()) {
                     setTimeout(() => this.scrollToBottom(), 50);
                 }
            }
        },
        error: (err) => console.error('Log poll error', err)
      });

    // Poll status every 2 seconds
    interval(2000)
      .pipe(
        takeUntilDestroyed(this.destroyRef),
        switchMap(() => this.api.getInstanceStatus(id))
      )
      .subscribe({
        next: (res) => this.status.set(res.status),
        error: (err) => console.error('Status poll error', err)
      });
  }

  scrollToBottom() {
    try {
      const el = this.logContainer.nativeElement;
      el.scrollTop = el.scrollHeight;
    } catch(err) { }
  }

  start() {
    const id = this.instanceId();
    if (!id) return;
    this.api.startInstance(id).subscribe({
      error: (err) => {
        if (err?.error?.errorKind === EULA_NOT_ACCEPTED_ERROR_KIND) {
          if (confirm(this.translate.instant('CONSOLE.EULA_REQUIRED'))) {
            this.api.acceptEula(id).subscribe({
              next: () => this.start(),
              error: () => console.error('Failed to accept Minecraft EULA')
            });
          }
        } else {
          console.error('Failed to start instance');
        }
      }
    });
  }

  stop() {
    const id = this.instanceId();
    if (!id) return;
    this.api.stopInstance(id).subscribe();
  }

  kill() {
    const id = this.instanceId();
    if (!id) return;
    this.api.killInstance(id).subscribe();
  }

  sendCommand() {
    const id = this.instanceId();
    const cmd = this.commandInput();
    if (!id || !cmd.trim()) return;

    this.api.sendCommand(id, cmd).subscribe(() => {
      this.commandInput.set('');
    });
  }
}
