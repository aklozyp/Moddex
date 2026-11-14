import { CreateInstanceRequest, Instance, UpdateInstanceRequest } from '../models/instance';
import { InstanceBootstrapResponse } from '../models/instance-bootstrap';
import { ServerPropertiesDto, ServerPropertiesUpdateRequest } from '../models/server-properties';
import { CompatibleLoader } from '../models/compatible-loader';
import { ServerSettings } from '../models/server-settings';
import { firstValueFrom, Observable } from 'rxjs';
import { inject, Injectable } from '@angular/core';
import { HttpClient, HttpResponse } from '@angular/common/http';
import { ServerService } from './server-service';

@Injectable({ providedIn: 'root' })
export class ApiService {
  private readonly http = inject(HttpClient);
  private readonly servers = inject(ServerService);

  getFromSelected<T>(path: string): Observable<T> {
    const base = this.servers.getCurrentOrigin();
    return this.http.get<T>(`${base}${path}`);
  }

  postToSelected<T>(path: string, body: any): Observable<T> {
    const base = this.servers.getCurrentOrigin();
    return this.http.post<T>(`${base}${path}`, body);
  }

  putToSelected<T>(path: string, body: any): Observable<T> {
    const base = this.servers.getCurrentOrigin();
    return this.http.put<T>(`${base}${path}`, body);
  }

  async getInstances(): Promise<Instance[]> {
    return await firstValueFrom(this.getFromSelected<Instance[]>('/api/v1/instance'));
  }

  async getInstanceById(id: string): Promise<Instance> {
    return await firstValueFrom(this.getFromSelected<Instance>(`/api/v1/instance/${id}`));
  }

  createInstance(request: CreateInstanceRequest): Observable<InstanceBootstrapResponse> {
    // The creation endpoint returns the bootstrap response (instance + initial
    // server properties), matching the backend InstancePropertiesController.
    return this.postToSelected<InstanceBootstrapResponse>('/api/v1/instance/bootstrap', request);
  }

  updateInstance(id: string, request: UpdateInstanceRequest): Observable<Instance> {
    return this.putToSelected<Instance>(`/api/v1/instance/${id}`, request);
  }

  getServerProperties(instanceId: string): Observable<ServerPropertiesDto> {
    return this.getFromSelected<ServerPropertiesDto>(`/api/v1/instance/${instanceId}/properties`);
  }

  getServerPropertiesBackup(instanceId: string): Observable<ServerPropertiesDto> {
    return this.getFromSelected<ServerPropertiesDto>(`/api/v1/instance/${instanceId}/properties/backup`);
  }

  updateServerProperties(instanceId: string, request: ServerPropertiesUpdateRequest): Observable<ServerPropertiesDto> {
    return this.putToSelected<ServerPropertiesDto>(`/api/v1/instance/${instanceId}/properties`, request);
  }

  resetServerProperties(instanceId: string): Observable<ServerPropertiesDto> {
    return this.postToSelected<ServerPropertiesDto>(`/api/v1/instance/${instanceId}/properties/reset`, {});
  }

  getMinecraftVersions(): Observable<string[]> {
    return this.getFromSelected<string[]>('/api/v1/version/minecraft/versions');
  }

  getCompatibleLoaders(minecraftVersion: string): Observable<CompatibleLoader[]> {
    return this.getFromSelected<CompatibleLoader[]>(`/api/v1/version/modloaders/compatible/${minecraftVersion}`);
  }

  getServerSettings(): Observable<ServerSettings> {
    return this.getFromSelected<ServerSettings>('/api/v1/serverSettings');
  }

  updateServerSettings(settings: ServerSettings): Observable<ServerSettings> {
    return this.putToSelected<ServerSettings>('/api/v1/serverSettings', settings);
  }

  downloadModpack(instanceId: string, format: 'modrinth' | 'curseforge'): Observable<HttpResponse<Blob>> {
    const base = this.servers.getCurrentOrigin();
    const params = new URLSearchParams({ format });
    return this.http.get(`${base}/api/v1/instance/${instanceId}/modpack?${params.toString()}`, {
      observe: 'response',
      responseType: 'blob',
    });
  }

  // Console
  startInstance(id: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/console/start`, {});
  }

  stopInstance(id: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/console/stop`, {});
  }

  killInstance(id: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/console/kill`, {});
  }

  sendCommand(id: string, command: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/console/command`, { command });
  }

  getInstanceLogs(id: string): Observable<string[]> {
    return this.getFromSelected<string[]>(`/api/v1/instance/${id}/console/logs`);
  }

  getInstanceStatus(id: string): Observable<{ status: string }> {
    return this.getFromSelected<{ status: string }>(`/api/v1/instance/${id}/console/status`);
  }

  checkEula(id: string): Observable<{ accepted: boolean }> {
    return this.getFromSelected<{ accepted: boolean }>(`/api/v1/instance/${id}/eula`);
  }

  acceptEula(id: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/eula/accept`, {});
  }

  // File Manager
  listFiles(id: string, path: string = ''): Observable<any[]> {
    const params = new URLSearchParams({ path });
    return this.getFromSelected<any[]>(`/api/v1/instance/${id}/files/list?${params.toString()}`);
  }

  getFileContent(id: string, path: string): Observable<string> {
    const params = new URLSearchParams({ path });
    return this.getFromSelected<string>(`/api/v1/instance/${id}/files/content?${params.toString()}`); // Note: getFromSelected expects JSON, might need text response handling
  }

  // Need special handling for text response
  getFileContentText(id: string, path: string): Observable<string> {
    const base = this.servers.getCurrentOrigin();
    const params = new URLSearchParams({ path });
    return this.http.get(`${base}/api/v1/instance/${id}/files/content?${params.toString()}`, { responseType: 'text' });
  }

  saveFileContent(id: string, path: string, content: string): Observable<any> {
    const base = this.servers.getCurrentOrigin();
    const params = new URLSearchParams({ path });
    return this.http.post(`${base}/api/v1/instance/${id}/files/content?${params.toString()}`, content);
  }

  deleteFile(id: string, path: string): Observable<any> {
    const base = this.servers.getCurrentOrigin();
    const params = new URLSearchParams({ path });
    return this.http.delete(`${base}/api/v1/instance/${id}/files?${params.toString()}`);
  }

  // Java Versions
  getJavaVersions(): Observable<string[]> {
    return this.getFromSelected<string[]>('/api/v1/java/versions');
  }

  // Backups
  listBackups(id: string): Observable<any[]> {
    return this.getFromSelected<any[]>(`/api/v1/instance/${id}/backups`);
  }

  createBackup(id: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/backups`, {});
  }

  deleteBackup(id: string, name: string): Observable<any> {
    const base = this.servers.getCurrentOrigin();
    return this.http.delete(`${base}/api/v1/instance/${id}/backups/${name}`);
  }

  restoreBackup(id: string, name: string): Observable<any> {
    return this.postToSelected<any>(`/api/v1/instance/${id}/backups/${name}/restore`, {});
  }

  // Modpack Import
  importModpack(id: string, file: File): Observable<any> {
    const base = this.servers.getCurrentOrigin();
    const form = new FormData();
    form.append('file', file, file.name);
    return this.http.post(`${base}/api/v1/instance/${id}/modpack/import`, form);
  }
}
