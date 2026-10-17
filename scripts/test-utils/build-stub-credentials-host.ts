// the host's state is mutable by design
/* oxlint-disable typescript/prefer-readonly-parameter-types */
import { readFileSync } from 'node:fs';
import { toShellArg } from '../to-shell-arg.ts';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for ssh to geoffcloud at the commands install-atc-gateway-credentials sends. It runs
// nothing: it answers as root's shell there would, from impd's state and the secrets directory's
// files. It knows a scripts/host/ script by its text on stdin; real bash runs those in their tests.
export interface StubCredentialsHostScenario {
  // the ssh destination the script must name
  readonly host: string;
  readonly dir: string;
  readonly impdPort: string;

  // what `impz info --json` prints
  readonly info: unknown;
  readonly secrets: Record<string, unknown>[];
  readonly tokens: Record<string, unknown>[];

  // the secrets directory's files, by name
  readonly files: Record<string, StubHostFile>;

  // every call fails as ssh does when it cannot reach the host
  readonly unreachable?: boolean;

  // that docker exec fails as it does when imp-host is stopped
  readonly stoppedAt?: 'info' | 'secret-ls' | 'token-ls';
  readonly installError?: string;

  // impd refuses `secret add` with this message and exit 2
  readonly secretAddError?: string;

  // the bearer's write fails with this message and exit 1
  readonly writeError?: string;

  // the saved bearer reads back with this appended
  readonly alterBearer?: string;

  // the saved token's check answers this, in place of a good identity
  readonly tokenCheck?: StubAnswer;

  // what `impz token new` prints, a line by default; mintError fails it with exit 1
  readonly minted?: string;
  readonly mintError?: string;

  // the files the final stat no longer finds
  readonly goneBeforeStat?: readonly string[];
}

interface StubHostFile {
  readonly content: string;
  readonly mode: string;
}

export interface StubCredentialsHost {
  readonly handle: StubHandler;

  // the value each `secret add` read on stdin, by secret name
  readonly secretValues: Readonly<Record<string, string>>;

  // the scenario's files, as the calls left them
  readonly files: Readonly<Record<string, StubHostFile>>;
}

export function buildStubCredentialsHost(
  scenario: StubCredentialsHostScenario,
): StubCredentialsHost {
  const secretValues: Record<string, string> = {};

  return {
    handle: (call) =>
      call.argv[0] === 'ssh' ? buildSSHAnswer({ scenario, secretValues }, call) : undefined,
    secretValues,
    files: scenario.files,
  };
}

interface HostState {
  readonly scenario: StubCredentialsHostScenario;
  readonly secretValues: Record<string, string>;
}

function buildSSHAnswer(state: HostState, call: StubCall) {
  const [, option, batch, destination, ...remote] = call.argv;

  return option === '-o' && batch === 'BatchMode=yes' && destination === state.scenario.host
    ? buildHostAnswer(state, call, remote)
    : undefined;
}

function buildHostAnswer(state: HostState, call: StubCall, remote: readonly string[]) {
  // OpenSSH's message for a refused connection, with the CR LF its log function ends a line with
  if (state.scenario.unreachable === true) {
    const name = state.scenario.host.replace(/^.*@/u, '');

    return {
      exitCode: 255,
      stderr: `ssh: connect to host ${name} port 22: Connection refused\r\n`,
    };
  }

  if (remote[0] === 'docker') {
    return buildDockerAnswer(state, remote.slice(1).join(' '), call.stdin);
  }

  return buildShellAnswer(state, remote.join(' '), call.stdin);
}

// docker 29.7.2's message for an exec in a stopped container, from moby's daemon/errors.go
const stoppedError =
  'Error response from daemon: container 4f6c0a2e9d1b7c4063034ef54c9cbfed806abcb7aee937d33c352266ea8718f6 is not running\n';

const secretAdd =
  'exec -i imp-host impz secret add glm --kind custom --hosts api.z.ai --header authorization --scheme bearer --json';

function buildDockerAnswer(state: HostState, line: string, stdin: string) {
  if (line === secretAdd) {
    return createSecret(state, stdin);
  }

  const reads = {
    'exec imp-host impz info --json': ['info', state.scenario.info],
    'exec imp-host impz secret ls --json': ['secret-ls', state.scenario.secrets],
    'exec imp-host impz token ls --json': ['token-ls', state.scenario.tokens],
  } as const;

  const read = Object.entries(reads).find(([command]) => command === line)?.[1];

  return read === undefined ? undefined : buildReadAnswer(state, read);
}

function buildReadAnswer(state: HostState, [step, value]: readonly [string, unknown]): StubAnswer {
  return state.scenario.stoppedAt === step
    ? { exitCode: 1, stderr: stoppedError }
    : { stdout: `${JSON.stringify(value, null, 2)}\n` };
}

// imp 1.0.0 reads the value's line and prints the secret with droppedGrants (SecretAddedSchema);
// it exits 2 for a usage error (packages/cli/src/run-action.ts)
function createSecret(state: HostState, stdin: string) {
  if (state.scenario.secretAddError !== undefined) {
    return { exitCode: 2, stderr: `${state.scenario.secretAddError}\n` };
  }

  state.secretValues['glm'] = stdin.split('\n')[0] ?? '';

  const secret = {
    name: 'glm',
    kind: 'custom',
    rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
    imps: [],
    createdAt: '2026-10-07T12:00:00.000Z',
  };

  state.scenario.secrets.push(secret);

  return { stdout: `${JSON.stringify({ ...secret, droppedGrants: 0 }, null, 2)}\n` };
}

const hostScripts = {
  write: readFileSync(new URL('../host/write-atc-gateway-token.sh', import.meta.url), 'utf8'),
  check: readFileSync(new URL('../host/check-atc-imp-token.sh', import.meta.url), 'utf8'),
  mint: readFileSync(new URL('../host/mint-atc-imp-token.sh', import.meta.url), 'utf8'),
};

function buildShellAnswer(state: HostState, line: string, stdin: string): StubAnswer | undefined {
  const dir = toShellArg(state.scenario.dir);
  const gatewayToken = toShellArg(`${state.scenario.dir}/gateway-token`);
  const impToken = toShellArg(`${state.scenario.dir}/imp-token`);
  const refusal = toShellArg(`${state.scenario.dir} is not a mount point; nothing written`);

  const answers: Record<string, () => StubAnswer | undefined> = {
    true: () => ({}),
    [`mountpoint -q ${dir} || { echo ${refusal} >&2; exit 1; }; install -d -m 0700 -o root -g root ${dir}`]:
      () => buildInstallAnswer(state),
    [`ls ${dir}`]: () => buildListAnswer(state),
    [`sha256sum ${gatewayToken}`]: () => buildSumAnswer(state),
    [`bash -s -- ${dir}`]: () => runHostScript(state, stdin),
    [`bash -s -- ${dir} ${toShellArg(state.scenario.impdPort)}`]: () =>
      stdin === hostScripts.check ? checkTokenFile(state) : undefined,
    [`stat -c '%n %U %a %s bytes' ${dir} ${gatewayToken} ${impToken}`]: () =>
      buildStatAnswer(state),
  };

  return answers[line]?.();
}

function buildInstallAnswer(state: HostState) {
  const error = state.scenario.installError;

  return error === undefined ? {} : { exitCode: 1, stderr: `${error}\n` };
}

function buildListAnswer(state: HostState) {
  const names = Object.keys(state.scenario.files).toSorted();

  return { stdout: names.map((name) => `${name}\n`).join('') };
}

function buildSumAnswer(state: HostState) {
  const path = `${state.scenario.dir}/gateway-token`;
  const file = state.scenario.files['gateway-token'];

  if (file === undefined) {
    return { exitCode: 1, stderr: `sha256sum: ${path}: No such file or directory\n` };
  }

  const hasher = new Bun.CryptoHasher('sha256');

  const sum = hasher.update(file.content + (state.scenario.alterBearer ?? '')).digest('hex');

  return { stdout: `${sum}  ${path}\n` };
}

function runHostScript(state: HostState, stdin: string): StubAnswer | undefined {
  if (stdin.startsWith(hostScripts.write)) {
    return writeGatewayToken(state, stdin.slice(hostScripts.write.length));
  }

  return stdin === hostScripts.mint ? createImpToken(state) : undefined;
}

// the script's `read` takes the line after it, and writes it back with a newline
function writeGatewayToken(state: HostState, rest: string) {
  if (state.scenario.writeError !== undefined) {
    return { exitCode: 1, stderr: `${state.scenario.writeError}\n` };
  }

  state.scenario.files['gateway-token'] = {
    content: `${rest.split('\n')[0] ?? ''}\n`,
    mode: '400',
  };

  return {};
}

// imp 1.0.0 prints the new token's secret alone on stdout, after its notice on stderr
// (packages/cli/src/commands/tokens.ts); the script saves only a mint of exactly one line
function createImpToken(state: HostState) {
  if (state.scenario.mintError !== undefined) {
    return { exitCode: 1, stderr: `${state.scenario.mintError}\n` };
  }

  state.scenario.tokens.push({
    name: 'atc-cloud',
    scope: 'manage',
    imps: ['harness-*'],
    sshKeys: [],
    grantable: ['glm'],
    createdAt: '2026-10-07T12:00:00.000Z',
  });

  const minted = state.scenario.minted ?? 'imp_fixture_minted_token\n';
  const notice = 'impz: token atc-cloud made; impd shows its secret only this once\n';

  if (minted.split('\n').length !== 2) {
    return { exitCode: 1, stderr: notice };
  }

  state.scenario.files['imp-token'] = { content: minted, mode: '400' };

  return { stderr: notice };
}

function checkTokenFile(state: HostState): StubAnswer {
  if (state.scenario.files['imp-token'] === undefined) {
    return { exitCode: 120 };
  }

  return (
    state.scenario.tokenCheck ?? { stdout: '{"json":{"kind":"token","name":"atc-cloud"}}\n200' }
  );
}

function buildStatAnswer(state: HostState): StubAnswer {
  const gone = new Set(state.scenario.goneBeforeStat);

  const found = ['gateway-token', 'imp-token'].map((name) => {
    const file = gone.has(name) ? undefined : state.scenario.files[name];
    const path = `${state.scenario.dir}/${name}`;

    return file === undefined
      ? { error: `stat: cannot statx '${path}': No such file or directory\n` }
      : { line: `${path} root ${file.mode} ${Buffer.byteLength(file.content)} bytes\n` };
  });

  const lines = found.map((entry) => entry.line ?? '').join('');
  const errors = found.map((entry) => entry.error ?? '').join('');

  return {
    exitCode: errors === '' ? 0 : 1,
    stdout: `${state.scenario.dir} root 700 4096 bytes\n${lines}`,
    stderr: errors,
  };
}
