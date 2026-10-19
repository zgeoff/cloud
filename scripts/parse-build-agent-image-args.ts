import { ExitError } from './exit-error.ts';
import { parseTimeoutDuration } from './parse-timeout-duration.ts';

export interface BuildRequest {
  readonly keep: boolean;
  readonly commit: string;
  readonly timeout: string;
  readonly timeoutMs: number;
}

export function parseBuildAgentImageArgs(args: readonly string[], timeout: string): BuildRequest {
  const keep = args[0] === '--keep';
  const rest = keep ? args.slice(1) : args;
  const [commit = 'origin/main'] = rest;

  if (rest.length > 1 || commit === '' || commit.startsWith('-')) {
    throw new ExitError(2, 'usage: build-agent-image.ts [--keep] [<commit on main>]');
  }

  return {
    keep,
    commit,
    timeout,
    timeoutMs: parseTimeoutDuration(timeout, 'AGENT_IMAGE_BUILD_TIMEOUT'),
  };
}
