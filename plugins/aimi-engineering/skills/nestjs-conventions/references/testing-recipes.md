# NestJS Per-Layer Testing Recipes

Full test recipes for each layer of the Controller → Service → Repository
stack, cross-checked against current `docs.nestjs.com` content via Context7
(`@nestjs/testing`, `fundamentals/unit-testing.md`) — see `../NOTICE.md`.

## Unit test: service in isolation, repository mocked by token

Provide the repository's DI token with a mock/`useValue` so the service runs
through its real constructor wiring, but every call to the repository hits a
test double instead of a real data store.

```typescript
import { Test } from '@nestjs/testing';
import { CatsService } from './cats.service';
import { CATS_REPOSITORY } from './cats.repository.token';

describe('CatsService', () => {
  let service: CatsService;
  const mockRepository = { findAll: jest.fn(), create: jest.fn() };

  beforeEach(async () => {
    const moduleRef = await Test.createTestingModule({
      providers: [
        CatsService,
        { provide: CATS_REPOSITORY, useValue: mockRepository },
      ],
    }).compile();

    service = moduleRef.get(CatsService);
  });

  it('delegates findAll to the repository', async () => {
    mockRepository.findAll.mockResolvedValue([{ id: 1, name: 'Whiskers' }]);
    await expect(service.findAll()).resolves.toEqual([{ id: 1, name: 'Whiskers' }]);
    expect(mockRepository.findAll).toHaveBeenCalled();
  });
});
```

No HTTP layer, no real database, no framework bootstrap — this is the
fastest layer to test and should carry the bulk of business-rule coverage.

## Integration test: controller against a real TestingModule

Build a real Nest DI graph (`controllers` + `providers`) and spy on/mock the
service the controller calls, so the test verifies the controller's actual
wiring (constructor injection, method delegation, response shape) without
needing a live HTTP server.

```typescript
import { Test } from '@nestjs/testing';
import { CatsController } from './cats.controller';
import { CatsService } from './cats.service';

describe('CatsController', () => {
  let controller: CatsController;
  let service: CatsService;

  beforeEach(async () => {
    const moduleRef = await Test.createTestingModule({
      controllers: [CatsController],
      providers: [CatsService],
    }).compile();

    service = moduleRef.get(CatsService);
    controller = moduleRef.get(CatsController);
  });

  it('returns what the service returns', async () => {
    jest.spyOn(service, 'findAll').mockResolvedValue(['test']);
    await expect(controller.findAll()).resolves.toEqual(['test']);
  });
});
```

### Auto-mocking dependencies with `useMocker`

When a controller or service has many collaborators and hand-writing a
`useValue` mock for each is noisy, `useMocker()` auto-generates mocks for
every token it doesn't explicitly handle:

```typescript
import { ModuleMocker, MockMetadata } from 'jest-mock';

const moduleMocker = new ModuleMocker(global);

const moduleRef = await Test.createTestingModule({
  controllers: [CatsController],
})
  .useMocker((token) => {
    if (token === CatsService) {
      return { findAll: jest.fn().mockResolvedValue(['test1', 'test2']) };
    }
    if (typeof token === 'function') {
      const mockMetadata = moduleMocker.getMetadata(token) as MockMetadata<any, any>;
      const Mock = moduleMocker.generateFromMetadata(mockMetadata) as ObjectConstructor;
      return new Mock();
    }
  })
  .compile();
```

## End-to-end test: endpoint via supertest

Boot a real `INestApplication` from the actual feature module, override only
the specific provider(s) that need a test double, and drive the endpoint
over HTTP with `supertest` so routing, pipes, guards, and filters all run
for real.

```typescript
import * as request from 'supertest';
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import { CatsModule } from '../../src/cats/cats.module';
import { CatsService } from '../../src/cats/cats.service';

describe('Cats (e2e)', () => {
  let app: INestApplication;
  const catsService = { findAll: () => ['test'] };

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      imports: [CatsModule],
    })
      .overrideProvider(CatsService)
      .useValue(catsService)
      .compile();

    app = moduleRef.createNestApplication();
    await app.init();
  });

  it('GET /cats', () => {
    return request(app.getHttpServer())
      .get('/cats')
      .expect(200)
      .expect({ data: catsService.findAll() });
  });

  afterAll(async () => {
    await app.close();
  });
});
```

## Choosing the right layer

- **New business rule** → unit test the service; mock the repository token.
- **New route, guard, or pipe wiring** → integration test the controller
  against a `TestingModule`.
- **Verifying the whole request/response contract** (status codes, headers,
  serialized shape, validation errors) → e2e test with `supertest` against a
  real `INestApplication`.
- Prefer pushing coverage down: a bug findable by a service unit test should
  not require an e2e test to catch it.
