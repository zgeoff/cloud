import type { StubHandler } from './build-stub-runner.ts';

// Stands in for atc-key, an unversioned bash script on the developer machine (~/.local/bin/atc-key,
// sha256 60a36fed46938acb416c10ba2d7586e8066ca1f30901d74a2db0fe9531076603)
export interface StubATCKeyScenario {
  readonly installed: boolean;
  readonly zaiKey: string;
}

export function buildStubATCKey(scenario: StubATCKeyScenario): StubHandler {
  const answers: Record<string, () => { exitCode?: number; stdout?: string } | undefined> = {
    // command -v prints nothing and exits 1 for a program it cannot find
    'sh -c command -v atc-key > /dev/null': () => ({ exitCode: scenario.installed ? 0 : 1 }),

    // run against a store holding ZAI_API_KEY on 2026-10-08, `atc-key zai` printed the key and a
    // newline (printf '%s\n')
    'atc-key zai': () => (scenario.installed ? { stdout: `${scenario.zaiKey}\n` } : undefined),
  };

  // atc-key's other providers and its failures are not modelled, so they fall to the runner's
  // exit 97
  return (call) => answers[call.argv.join(' ')]?.();
}
