import { ChangeDetectionStrategy, Component } from '@angular/core';
import { CommonModule } from '@angular/common';

@Component({
  selector: 'app-mod-card-skeleton',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './mod-card-skeleton.html',
  styleUrl: './mod-card-skeleton.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ModCardSkeletonComponent {
  readonly titleWidth = this.randomInt(46, 72);
  readonly subtitleWidth = this.randomInt(32, 58);
  readonly badgeWidths = this.generateWidths(this.randomInt(1, 3), 52, 118);
  readonly descriptionWidths = this.generateWidths(this.randomInt(2, 3), 62, 88);
  readonly statWidths = this.generateWidths(2, 76, 112);
  readonly chipWidth = this.randomInt(68, 120);
  readonly buttonWidth = this.randomInt(126, 162);

  private generateWidths(count: number, min: number, max: number): number[] {
    return Array.from({ length: count }, () => this.randomInt(min, max));
  }

  private randomInt(min: number, max: number): number {
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }
}
