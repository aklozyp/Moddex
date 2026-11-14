import {ChangeDetectionStrategy, Component} from '@angular/core';
import {CommonModule} from "@angular/common";

@Component({
  selector: 'app-instance-card-skeleton',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './instance-card-skeleton.html',
  styleUrl: './instance-card-skeleton.scss',
  changeDetection: ChangeDetectionStrategy.OnPush
})
export class InstanceCardSkeleton {
  readonly titleWidth = this.randomPercentage(30, 52);
  readonly bodyLineWidths = this.createBodyLineWidths();
  readonly categoryWidths = this.createTagWidths(this.randomInt(2, 4), 56, 110);
  readonly stats = Array.from({length: 3});

  private createBodyLineWidths(): number[] {
    const lineCount = this.randomInt(2, 3);
    return Array.from({length: lineCount}, (_, index) => {
      const min = index === 0 ? 58 : 42;
      const max = index === 0 ? 86 : 72;
      return this.randomPercentage(min, max);
    });
  }

  private createTagWidths(count: number, min: number, max: number): number[] {
    return Array.from({length: count}, () => this.randomInt(min, max));
  }

  private randomPercentage(min: number, max: number): number {
    return this.randomInt(min, max);
  }

  private randomInt(min: number, max: number): number {
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }
}
