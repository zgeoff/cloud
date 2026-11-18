import type { StubHandler } from './build-stub-runner.ts';

// Stands in for gh's `auth token`, which prints the stored token and a newline (cli/cli's
// pkg/cmd/auth/token/token.go)
export function buildStubGHAuthToken(token: string): StubHandler {
  return (call) =>
    call.argv.join(' ') === 'gh auth token --hostname github.com'
      ? { stdout: `${token}\n` }
      : undefined;
}
