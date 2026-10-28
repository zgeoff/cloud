import { faker } from '@faker-js/faker';
import type { ImpActivity } from '../plan-slot-evictions.ts';

export function buildMockImpActivity(overrides: Partial<ImpActivity> = {}): ImpActivity {
  return {
    name: `pv-${faker.string.hexadecimal({ length: 8, casing: 'lower', prefix: '' })}-${String(faker.number.int({ min: 1, max: 9999 }))}`,
    state: 'running',
    lastActiveAt: faker.date.recent(),
    ...overrides,
  };
}
