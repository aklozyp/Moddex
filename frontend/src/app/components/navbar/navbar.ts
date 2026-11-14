import { Component } from '@angular/core';
import {ModdexService} from '../../services/moddex-service';
import {TranslatePipe} from '@ngx-translate/core';
import {RouterLink} from "@angular/router";
import {MatIconModule} from "@angular/material/icon";

@Component({
  selector: 'app-navbar',
  imports: [
    TranslatePipe,
    RouterLink,
    MatIconModule
  ],
  templateUrl: './navbar.html',
  styleUrl: './navbar.scss'
})
export class Navbar {

  constructor(protected moddexService: ModdexService) {
  }
}
