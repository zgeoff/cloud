import { readdir } from 'node:fs/promises';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for the agent image that check-agent-image.ts runs its checks in: `docker run` with the
// check directory mounted, or `impz cp` of it and then `impz exec`. It lists the directory when the
// image receives it, since the check removes it after the run.
export interface StubAgentImageGuestScenario {
  // the guest's result for the `bash -s` run
  readonly guest: StubAnswer;

  // the result of `impz cp`; the copy succeeds silently when absent
  readonly copy?: StubAnswer;
}

export interface StubAgentImageGuest {
  readonly handler: StubHandler;

  // the sorted file names of each check directory the image received, in order
  readonly seen: readonly (readonly string[])[];
}

export function buildStubAgentImageGuest(
  scenario: Readonly<StubAgentImageGuestScenario>,
): StubAgentImageGuest {
  const seen: string[][] = [];

  return {
    handler: async (call) => {
      const dir = findCheckDir(call);

      if (dir !== undefined) {
        const files = await readdir(dir);

        seen.push(files.toSorted());
      }

      return buildAnswer(scenario, call);
    },
    seen,
  };
}

// the host side of `-v <dir>:/run/agent-image-check:ro`, or the source of `impz cp`
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
