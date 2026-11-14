import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule } from '@angular/common/http/testing';

import { ModdexService } from './moddex-service';

describe('ModdexService', () => {
  let service: ModdexService;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    });
    service = TestBed.inject(ModdexService);
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });
});
