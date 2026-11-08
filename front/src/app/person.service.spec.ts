import { TestBed } from '@angular/core/testing';

import { PersonService } from './person.service';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';

describe('PersonService', () => {
  let service: PersonService;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(PersonService);
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });
});
