// Logs docker in to ghcr.io with the workflow token, for a CI job that pulls a private package.
// The token goes to docker on stdin, never on its command line.
const token = process.env['GH_TOKEN'];
const actor = process.env['GITHUB_ACTOR'];

if (!token || !actor) {
  console.error('login-ghcr: GH_TOKEN and GITHUB_ACTOR must both be set');
  process.exit(1);
}

const login = Bun.spawn(['docker', 'login', 'ghcr.io', '-u', actor, '--password-stdin'], {
  stdin: new TextEncoder().encode(token),
  stdout: 'inherit',
  stderr: 'inherit',
});

const exitCode = await login.exited;

process.exit(exitCode);
