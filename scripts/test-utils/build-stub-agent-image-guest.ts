import { readdir } from 'node:fs/promises';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

export interface StubAgentImageGuestScenario {
  readonly guest: StubAnswer;

  // the result of `impz cp`; the copy succeeds silently when absent
  readonly copy?: StubAnswer;
}

export interface StubAgentImageGuest {
  readonly handler: StubHandler;

  readonly seen: readonly (readonly string[])[];
}

export function buildStubAgentImageGuest(
  scenario: Readonly<StubAgentImageGuestScenario>,
): StubAgentImageGuest {
  const seen: string[][] = [];

  return {
    handler: async (call) => {
      const directory = findCheckDir(call);

      if (directory !== undefined) {
        // listed on receipt, since the check removes the directory after the run
        const files = await readdir(directory);

        seen.push(files.toSorted());
      }

      return buildAnswer(scenario, call);
    },
    seen,
  };
}

function findCheckDir(call: StubCall) {
  const [program, verb, source] = call.argv;

  if (program === 'docker' && verb === 'run') {
    return call.argv[5]?.replace(/:\/run\/agent-image-check:ro$/u, '');
  }

  return program === 'impz' && verb === 'cp' ? source : undefined;
}

function buildAnswer(scenario: Readonly<StubAgentImageGuestScenario>, call: StubCall) {
  const [program, verb] = call.argv;

  if (program === 'impz' && verb === 'cp') {
    return scenario.copy ?? {};
  }

  const isGuest =
    (program === 'docker' && verb === 'run') || (program === 'impz' && verb === 'exec');

  return isGuest ? scenario.guest : undefined;
}
