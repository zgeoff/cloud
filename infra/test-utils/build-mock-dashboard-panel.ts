import { faker } from '@faker-js/faker';
import type { DashboardPanel } from '../build-dashboard.ts';

// legend's absence is behaviour (the target carries no legendFormat), so an override of
// undefined leaves it out: with exactOptionalPropertyTypes a plain override cannot
type DashboardPanelOverrides = Partial<Omit<DashboardPanel, 'legend'>> & {
  readonly legend?: string | undefined;
};

export function buildMockDashboardPanel(overrides: DashboardPanelOverrides = {}): DashboardPanel {
  const { legend, ...fields } = { legend: faker.lorem.word(), ...overrides };

  return {
    title: faker.lorem.words(3),
    type: 'timeseries',
    expr: `up{job="${faker.internet.domainWord()}"}`,
    width: faker.number.int({ min: 1, max: 24 }),
    height: faker.number.int({ min: 1, max: 12 }),
    ...fields,
    ...(legend === undefined ? {} : { legend }),
  };
}
