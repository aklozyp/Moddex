import { Injectable } from '@angular/core';

@Injectable({ providedIn: 'root' })
export class ServerService {
  private readonly currentOrigin = `${window.location.protocol}//${window.location.hostname}:7870`;

  getCurrentOrigin(): string {
    return this.currentOrigin;
  }
}
