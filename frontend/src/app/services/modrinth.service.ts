import { inject, Injectable } from '@angular/core';
import { HttpClient, HttpErrorResponse, HttpParams } from '@angular/common/http';
import { Observable, throwError } from 'rxjs';
import { catchError } from 'rxjs/operators';
import { ModrinthSearchResponse } from '../models/modrinth/modrinth-search.model';
import { ModrinthProject } from '../models/modrinth/modrinth-project.model';
import { ModrinthVersion } from '../models/modrinth/modrinth-version.model';
import { ModrinthFiltersResponse } from '../models/modrinth/modrinth-filters.model';
import { InstallModRequest, InstalledMod } from '../models/mod.model';
import { ModDataProvider } from '../models/mod-data-provider';
import { ServerService } from './server-service';

export interface ModrinthProjectDetailsResponse {
  project: ModrinthProject;
  versions: ModrinthVersion[];
  provider?: ModDataProvider;
}

@Injectable({
  providedIn: 'root'
})
export class ModrinthService {
  private readonly http = inject(HttpClient);
  private readonly servers = inject(ServerService);

  searchMods(
    instanceId: string,
    query: string,
    limit: number,
    offset: number,
    filters?: { categories?: string[], sort?: string, index?: string }
  ): Observable<ModrinthSearchResponse> {
    let params = new HttpParams()
      .set('query', query)
      .set('limit', limit.toString())
      .set('offset', offset.toString());

    if (filters) {
      if (filters.categories?.length) {
        for (const category of filters.categories) {
          params = params.append('categories', category);
        }
      }
      if (filters.index) {
        params = params.set('index', filters.index);
      }
    }

    return this.http
      .get<ModrinthSearchResponse>(this.buildUrl(`/instance/${instanceId}/modrinth/search`), { params })
      .pipe(catchError(error => this.handleError('searchMods', error)));
  }

  getRecommendedMods(
    instanceId: string,
    limit: number,
    offset: number,
    options?: { categories?: string[]; index?: string }
  ): Observable<ModrinthSearchResponse> {
    let params = new HttpParams()
      .set('limit', limit.toString())
      .set('offset', offset.toString());

    if (options?.index) {
      params = params.set('index', options.index);
    }

    if (options?.categories?.length) {
      for (const category of options.categories) {
        params = params.append('categories', category);
      }
    }

    return this.http
      .get<ModrinthSearchResponse>(this.buildUrl(`/instance/${instanceId}/modrinth/recommended`), { params })
      .pipe(catchError(error => this.handleError('getRecommendedMods', error)));
  }

  getModDetails(instanceId: string, projectId: string): Observable<ModrinthProjectDetailsResponse> {
    return this.http
      .get<ModrinthProjectDetailsResponse>(this.buildUrl(`/instance/${instanceId}/modrinth/projects/${projectId}`))
      .pipe(catchError(error => this.handleError('getModDetails', error)));
  }

  getFilters(): Observable<ModrinthFiltersResponse> {
    return this.http
      .get<ModrinthFiltersResponse>(this.buildUrl('/modrinth/filters'))
      .pipe(catchError(error => this.handleError('getFilters', error)));
  }

  installMod(
    instanceId: string,
    projectId: string,
    versionId?: string,
    provider?: ModDataProvider,
  ): Observable<{ installed: InstalledMod[] }> {
    const body: InstallModRequest = { projectId, versionId, provider };
    return this.http
      .post<{ installed: InstalledMod[] }>(this.buildUrl(`/instance/${instanceId}/mods`), body)
      .pipe(catchError(error => this.handleError('installMod', error)));
  }

  getInstalledMods(instanceId: string): Observable<InstalledMod[]> {
    return this.http
      .get<InstalledMod[]>(this.buildUrl(`/instance/${instanceId}/mods`))
      .pipe(catchError(error => this.handleError('getInstalledMods', error)));
  }

  removeMod(instanceId: string, projectId: string): Observable<InstalledMod> {
    return this.http
      .delete<InstalledMod>(this.buildUrl(`/instance/${instanceId}/mods/${projectId}`))
      .pipe(catchError(error => this.handleError('removeMod', error)));
  }

  private buildUrl(path: string): string {
    return `${this.servers.getCurrentOrigin()}/api/v1${path}`;
  }

  private handleError(operation: string, error: unknown): Observable<never> {
    console.error(`[ModrinthService] ${operation} failed`, error);
    if (error instanceof HttpErrorResponse && typeof error.error === 'string') {
      const message = error.error.startsWith('<!doctype')
        ? 'Received an unexpected response from the server.'
        : error.error;
      return throwError(() => new Error(`${operation} failed: ${message}`));
    }

    return throwError(() => error instanceof Error ? error : new Error(`${operation} failed.`));
  }
}
