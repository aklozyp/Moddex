import { Component, Input } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';

@Component({
  selector: 'app-button',
  standalone: true,
  imports: [
    MatIconModule
  ],
  templateUrl: './button.html',
  styleUrls: ['./button.scss']
})
export class ButtonComponent {
  @Input() text?: string;
  @Input() icon?: string;
  @Input() styleType: 'primary' | 'normal' | 'optional' = 'normal';
  @Input() disabled = false;
}
