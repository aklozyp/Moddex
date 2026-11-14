import { Injectable, inject } from '@angular/core';
import { ApiService } from './api-service';
import {catchError, from, retry, throwError} from 'rxjs';


@Injectable({
  providedIn: 'root'
})
export class ModdexService {

  private apiService = inject(ApiService);

  serverName = "Moddex"

  getInstances() {
    return from(this.apiService.getInstances()).pipe(
      retry({ count: 3, delay: 1000 }),
      catchError(err => {
        return throwError(() => new Error('Instances could not be loaded.'));
      })
    );
  }
}
