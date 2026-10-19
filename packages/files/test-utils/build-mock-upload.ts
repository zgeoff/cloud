import { faker } from '@faker-js/faker';
import type { Upload } from '../types.ts';

// an agent upload of a PNG that expires a week after it was made
export function buildMockUpload(overrides: Partial<Upload> = {}): Upload {
  const createdAt = overrides.createdAt ?? faker.date.recent();

  return {
    id: faker.string.alphanumeric(22),
    filename: `${faker.system.fileName({ extensionCount: 0 })}.png`,
    contentType: 'image/png',
    size: faker.number.int({ min: 1, max: 1_000_000 }),
    sha256: faker.string.hexadecimal({ length: 64, casing: 'lower', prefix: '' }),
    uploader: 'agent',
    label: faker.lorem.words(3),
    link: faker.internet.url(),
    expiresAt: new Date(createdAt.getTime() + 7 * 24 * 60 * 60 * 1000),
    ...overrides,
    createdAt,
  };
}
