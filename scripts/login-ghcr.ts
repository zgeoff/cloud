// The token goes to docker on stdin, never on its command line.
const token = process.env['GH_TOKEN'];
const actor = process.env['GITHUB_ACTOR'];

if (token === undefined || token === '' || actor === undefined || actor === '') {
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
