import { Component, EventEmitter, Output } from '@angular/core';
import { ButtonComponent } from "../button/button";
import { TranslatePipe } from "@ngx-translate/core";

@Component({
  selector: 'app-save-bar',
  standalone: true,
  imports: [
    ButtonComponent,
    TranslatePipe
  ],
  templateUrl: './save-bar.html',
  styleUrls: ['./save-bar.scss']
})
export class SaveBarComponent {
  @Output() save = new EventEmitter<void>();
  @Output() discard = new EventEmitter<void>();
}
