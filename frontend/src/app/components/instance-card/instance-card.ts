import {ChangeDetectionStrategy, Component, input} from '@angular/core';
import {Instance} from '../../models/instance';
import {MatIconModule} from '@angular/material/icon';
import {ButtonComponent} from '../button/button';
import {RouterLink} from '@angular/router';

@Component({
  selector: 'app-instance-card',
  standalone: true,
  imports: [
    MatIconModule,
    ButtonComponent,
    RouterLink
  ],
  templateUrl: './instance-card.html',
  styleUrl: './instance-card.scss',
  changeDetection: ChangeDetectionStrategy.OnPush
})
export class InstanceCard {
  instance = input.required<Instance>();
}