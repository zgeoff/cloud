import type { StubATCKeyScenario } from './build-stub-atc-key.ts';
import { buildStubATCKey } from './build-stub-atc-key.ts';
import type {
  StubCredentialsHost,
  StubCredentialsHostScenario,
} from './build-stub-credentials-host.ts';
import { buildStubCredentialsHost } from './build-stub-credentials-host.ts';
import type { StubOp, StubOpScenario } from './build-stub-op.ts';
import { buildStubOp } from './build-stub-op.ts';
import type { StubRunner } from './build-stub-runner.ts';
import { buildStubRunner } from './build-stub-runner.ts';

export interface StubCredentialToolsScenario {
  readonly op: StubOpScenario;
  readonly atcKey: StubATCKeyScenario;
  readonly host: StubCredentialsHostScenario;
}

export interface StubCredentialTools extends StubRunner {
  readonly op: StubOp;
  readonly host: StubCredentialsHost;
}

export function buildStubCredentialTools(
  scenario: StubCredentialToolsScenario,
): StubCredentialTools {
  const op = buildStubOp(scenario.op);
  const host = buildStubCredentialsHost(scenario.host);
  const runner = buildStubRunner(op.answer, buildStubATCKey(scenario.atcKey), host.answer);

  return { run: runner.run, calls: runner.calls, op, host };
}
