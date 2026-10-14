import { toShellArg } from './to-shell-arg.ts';

export interface AgentImageGuestInput {
  // the Dockerfile's pins, by name
  readonly pins: Readonly<Record<string, string>>;
  readonly mode: 'imp' | 'docker';

  // scripts/agent-image-check-guest.sh
  readonly body: string;
}

// The script the image's bash reads on stdin: each `<NAME>_VERSION` pin as a shell assignment, then
// check_mode, then the checks. The snapshot stamp and the sums stay out, since no check reads them.
export function buildAgentImageGuestScript(input: Readonly<AgentImageGuestInput>): string {
  const assignments = Object.keys(input.pins)
    .filter((name) => name.endsWith('_VERSION'))
    .map((name) => `${name}=${toShellArg(input.pins[name] ?? '')}\n`);

  return `${assignments.join('')}check_mode=${toShellArg(input.mode)}\n${input.body}`;
}
