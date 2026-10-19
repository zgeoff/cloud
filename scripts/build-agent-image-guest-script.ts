import { toShellArg } from './to-shell-arg.ts';

export interface AgentImageGuestInput {
  readonly pins: Readonly<Record<string, string>>;
  readonly mode: 'imp' | 'docker';

  readonly body: string;
}

export function buildAgentImageGuestScript(input: Readonly<AgentImageGuestInput>): string {
  // the snapshot stamp and the sums stay out, since no check reads them
  const assignments = Object.keys(input.pins)
    .filter((name) => name.endsWith('_VERSION'))
    .map((name) => `${name}=${toShellArg(input.pins[name] ?? '')}\n`);

  return `${assignments.join('')}check_mode=${toShellArg(input.mode)}\n${input.body}`;
}
