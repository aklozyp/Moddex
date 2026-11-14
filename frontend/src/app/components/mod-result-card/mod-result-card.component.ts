import { ChangeDetectionStrategy, Component, EventEmitter, Output, input } from '@angular/core';
import { CommonModule, NgOptimizedImage } from '@angular/common';
import { MatIconModule } from '@angular/material/icon';
import { MatTooltipModule } from '@angular/material/tooltip';
import { MatButtonModule } from '@angular/material/button';
import { MatChipsModule } from '@angular/material/chips';
import { MatCardModule } from '@angular/material/card';
import { TranslatePipe } from '@ngx-translate/core';
import { ModrinthSearchHit } from '../../models/modrinth/modrinth-search.model';
import { ModDataProvider } from '../../models/mod-data-provider';

@Component({
  selector: 'app-mod-result-card',
  standalone: true,
  imports: [
    CommonModule,
    MatIconModule,
    MatTooltipModule,
    MatButtonModule,
    MatChipsModule,
    MatCardModule,
    NgOptimizedImage,
    TranslatePipe,
  ],
  templateUrl: './mod-result-card.component.html',
  styleUrls: ['./mod-result-card.component.scss'],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ModResultCardComponent {
  readonly mod = input.required<ModrinthSearchHit>();
  readonly disableActions = input<boolean>(false);

  @Output() readonly add = new EventEmitter<ModrinthSearchHit>();
  @Output() readonly showDetails = new EventEmitter<string>();

  protected onCardClick(): void {
    this.showDetails.emit(this.mod().project_id);
  }

  protected onAddClick(event: MouseEvent): void {
    event.stopPropagation();
    if (this.disableActions()) {
      return;
    }

    this.add.emit(this.mod());
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

  protected iconSource(): string {
    return this.mod().icon_url || './assets/images/default-mod-icon.png';
  }
}
