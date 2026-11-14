import { ChangeDetectionStrategy, Component, EventEmitter, Output, input } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatTooltipModule } from '@angular/material/tooltip';
import { MatChipsModule } from '@angular/material/chips';
import { MatDividerModule } from '@angular/material/divider';
import { InstalledMod } from '../../models/mod.model';
import { ModDataProvider } from '../../models/mod-data-provider';
import { TranslatePipe } from '@ngx-translate/core';

@Component({
  selector: 'app-installed-mod-list',
  standalone: true,
  imports: [
    CommonModule,
    MatCardModule,
    MatButtonModule,
    MatIconModule,
    MatTooltipModule,
    MatChipsModule,
    MatDividerModule,
    TranslatePipe,
  ],
  templateUrl: './installed-mod-list.component.html',
  styleUrls: ['./installed-mod-list.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class InstalledModListComponent {
  readonly mods = input.required<InstalledMod[]>();
  readonly removingIds = input<string[]>([]);
  readonly disableActions = input<boolean>(false);

  @Output() readonly viewDetails = new EventEmitter<InstalledMod>();
  @Output() readonly remove = new EventEmitter<InstalledMod>();
  @Output() readonly download = new EventEmitter<InstalledMod>();

  protected onView(mod: InstalledMod): void {
    this.viewDetails.emit(mod);
  }

  protected onRemove(event: MouseEvent, mod: InstalledMod): void {
    event.stopPropagation();
    this.remove.emit(mod);
  }

  protected onDownload(event: MouseEvent, mod: InstalledMod): void {
    event.stopPropagation();
    if (!mod.downloadUrl) {
      return;
    }

    // Emit so parent can hook custom behaviour; fall back to opening in new tab.
    this.download.emit(mod);

    if (typeof window === 'undefined' || typeof document === 'undefined') {
      return;
    }

    const anchor = document.createElement('a');
    anchor.href = mod.downloadUrl;
    anchor.download = '';
    anchor.rel = 'noopener';
    anchor.target = '_blank';
    anchor.style.display = 'none';
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
  }

  protected isRemoving(mod: InstalledMod): boolean {
    return this.removingIds().includes(mod.projectId);
  }

  protected displayName(mod: InstalledMod): string {
    return mod.displayName || mod.projectSlug || mod.projectId;
  }

  protected providerLabel(provider?: ModDataProvider): string {
    switch (provider) {
      case 'CURSEFORGE':
        return 'CurseForge';
      case 'MODRINTH':
      default:
        return 'Modrinth';
    }
  }
}
