import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';

import { ApiService } from './api-service';
import { ServerService } from './server-service';

const BASE_ORIGIN = 'http://backend.test';
const INSTANCES_ENDPOINT = BASE_ORIGIN + '/api/v1/instance';
const CREATE_INSTANCE_ENDPOINT = BASE_ORIGIN + '/api/v1/instance/bootstrap';
const SETTINGS_ENDPOINT = BASE_ORIGIN + '/api/v1/serverSettings';

describe('ApiService', () => {
  let service: ApiService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        ApiService,
        {
          provide: ServerService,
          useValue: { getCurrentOrigin: () => BASE_ORIGIN },
        },
      ],
    });

    service = TestBed.inject(ApiService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('fetches instances from the current origin', async () => {
    const instancesPromise = service.getInstances();
    const request = httpMock.expectOne(INSTANCES_ENDPOINT);
    expect(request.request.method).toBe('GET');
    request.flush([{ id: '1', name: 'Example' }]);

    const instances = await instancesPromise;
    expect(instances.length).toBe(1);
    expect(instances[0].name).toBe('Example');
  });

  it('creates a new instance via POST to the bootstrap endpoint', () => {
    const payload = { name: 'Test Instance' } as any;

    service.createInstance(payload).subscribe(response => {
      expect(response).toEqual({ status: 'ok' } as any);
    });

    const request = httpMock.expectOne(CREATE_INSTANCE_ENDPOINT);
    expect(request.request.method).toBe('POST');
    expect(request.request.body).toEqual(payload);
    request.flush({ status: 'ok' });
  });

  it('updates server settings via PUT', () => {
    const settings = { projectPath: '/opt/moddex' } as any;

    service.updateServerSettings(settings).subscribe(response => {
      expect(response).toEqual(settings);
    });

    const request = httpMock.expectOne(SETTINGS_ENDPOINT);
    expect(request.request.method).toBe('PUT');
    expect(request.request.body).toEqual(settings);
    request.flush(settings);
  });
});
