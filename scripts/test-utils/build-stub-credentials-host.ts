import { readFileSync } from 'node:fs';
import { toShellArg } from '../to-shell-arg.ts';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

interface StubHostFile {
  readonly content: string;
  readonly mode: string;
}

export interface StubCredentialsHostScenario {
  readonly host: string;
  readonly directory: string;
  readonly impdPort: string;

  readonly info: unknown;
  readonly secrets: Record<string, unknown>[];
  readonly tokens: Record<string, unknown>[];

  readonly files: Record<string, StubHostFile>;

  readonly unreachable?: boolean;

  readonly stoppedAt?: 'info' | 'secret-ls' | 'token-ls';
  readonly installError?: string;

  readonly secretAddError?: string;

  readonly writeError?: string;

  readonly alterBearer?: string;

  readonly tokenCheck?: StubAnswer;

  readonly minted?: string;
  readonly mintError?: string;

  readonly goneBeforeStat?: readonly string[];
}

export interface StubCredentialsHost {
  readonly answer: StubHandler;

  readonly secretValues: Readonly<Record<string, string>>;

  readonly files: Readonly<Record<string, StubHostFile>>;
}

export function buildStubCredentialsHost(
  scenario: StubCredentialsHostScenario,
): StubCredentialsHost {
  const secretValues: Record<string, string> = {};

  return {
    answer: (call) =>
      call.argv[0] === 'ssh' ? answerSSHCall({ scenario, secretValues }, call) : undefined,
    secretValues,
    files: scenario.files,
  };
}

interface HostState {
  readonly scenario: StubCredentialsHostScenario;
  readonly secretValues: Record<string, string>;
}

function answerSSHCall(state: HostState, call: StubCall) {
  const [, batchOption, batch, timeoutOption, timeout, destination, line, ...rest] = call.argv;

  const isHostCall =
    batchOption === '-o' &&
    batch === 'BatchMode=yes' &&
    timeoutOption === '-o' &&
    timeout === 'ConnectTimeout=15' &&
    destination === `root@${state.scenario.host}` &&
    rest.length === 0;

  return isHostCall && line !== undefined ? answerHostCall(state, call, line) : undefined;
}

function answerHostCall(state: HostState, call: StubCall, line: string) {
  // OpenSSH's message for a refused connection, with the CR LF its log function ends a line with
  if (state.scenario.unreachable === true) {
    return {
      exitCode: 255,
      stderr: `ssh: connect to host ${state.scenario.host} port 22: Connection refused\r\n`,
    };
  }

  return answerDockerCall(state, line, call.stdin) ?? answerShellCall(state, line, call.stdin);
}

const secretAdd = toLine([
  'docker',
  'exec',
  '-i',
  'imp-host',
  'impz',
  'secret',
  'add',
  'glm',
  '--kind',
  'custom',
  '--hosts',
  'api.z.ai',
  '--header',
  'authorization',
  '--scheme',
  'bearer',
  '--json',
]);

function answerDockerCall(state: HostState, line: string, stdin: string) {
  if (line === secretAdd) {
    return createSecret(state, stdin);
  }

  const reads = {
    [toLine(['docker', 'exec', 'imp-host', 'impz', 'info', '--json'])]: [
      'info',
      state.scenario.info,
    ],
    [toLine(['docker', 'exec', 'imp-host', 'impz', 'secret', 'ls', '--json'])]: [
      'secret-ls',
      state.scenario.secrets,
    ],
    [toLine(['docker', 'exec', 'imp-host', 'impz', 'token', 'ls', '--json'])]: [
      'token-ls',
      state.scenario.tokens,
    ],
  } as const;

  const read = Object.entries(reads).find(([command]) => command === line)?.[1];

  return read === undefined ? undefined : buildReadAnswer(state, read);
}

function toLine(words: readonly string[]): string {
  return words.map((word) => toShellArg(word)).join(' ');
}

function createSecret(state: HostState, stdin: string) {
  if (state.scenario.secretAddError !== undefined) {
    // imp 1.0.0 exits 2 for a usage error (packages/cli/src/run-action.ts)
    return { exitCode: 2, stderr: `${state.scenario.secretAddError}\n` };
  }

  // imp 1.0.0 reads only the value's line
  state.secretValues['glm'] = stdin.split('\n')[0] ?? '';

  const secret = {
    name: 'glm',
    kind: 'custom',
    rules: [{ host: 'api.z.ai', header: 'authorization', scheme: 'bearer' }],
    imps: [],
    createdAt: '2026-10-07T12:00:00.000Z',
  };

  state.scenario.secrets.push(secret);

  // imp 1.0.0 prints the added secret with droppedGrants (SecretAddedSchema)
  return { stdout: `${JSON.stringify({ ...secret, droppedGrants: 0 }, null, 2)}\n` };
}

// docker 29.7.2's message for an exec in a stopped container, from moby's daemon/errors.go
const stoppedError =
  'Error response from daemon: container 4f6c0a2e9d1b7c4063034ef54c9cbfed806abcb7aee937d33c352266ea8718f6 is not running\n';

function buildReadAnswer(state: HostState, [step, value]: readonly [string, unknown]): StubAnswer {
  return state.scenario.stoppedAt === step
    ? { exitCode: 1, stderr: stoppedError }
    : { stdout: `${JSON.stringify(value, null, 2)}\n` };
}

const hostScripts = {
  // a host script is known by its text on stdin; real bash runs each in its own test
  write: readFileSync(new URL('../host/write-atc-gateway-token.sh', import.meta.url), 'utf8'),
  check: readFileSync(new URL('../host/check-atc-imp-token.sh', import.meta.url), 'utf8'),
  mint: readFileSync(new URL('../host/mint-atc-imp-token.sh', import.meta.url), 'utf8'),
};

function answerShellCall(state: HostState, line: string, stdin: string): StubAnswer | undefined {
  const directory = state.scenario.directory;
  const gatewayToken = `${directory}/gateway-token`;
  const impToken = `${directory}/imp-token`;

  const install =
    'mountpoint -q "$1" || { echo "$1 is not a mount point; nothing written" >&2; exit 1; }; install -d -m 0700 -o root -g root "$1"';

  const answers: Record<string, () => StubAnswer | undefined> = {
    [toLine(['true'])]: () => ({}),
    [toLine(['bash', '-c', install, 'bash', directory])]: () => buildInstallAnswer(state),
    [toLine(['ls', directory])]: () => buildListAnswer(state),
    [toLine(['sha256sum', gatewayToken])]: () => buildSumAnswer(state),
    [toLine(['bash', '-s', '--', directory])]: () =>
      stdin.startsWith(hostScripts.write) ? runHostScript(state, stdin) : undefined,
    [toLine(['bash', '-s', '--', directory, 'docker', 'exec', 'imp-host', 'impz'])]: () =>
      stdin === hostScripts.mint ? runHostScript(state, stdin) : undefined,
    [toLine([
      'bash',
      '-s',
      '--',
      directory,
      state.scenario.impdPort,
      'docker',
      'exec',
      '-e',
      'IMP_TOKEN',
      '-e',
      'IMP_URL',
      'imp-host',
      'impz',
    ])]: () => (stdin === hostScripts.check ? checkTokenFile(state) : undefined),
    [toLine(['stat', '-c', '%n %U %a %s bytes', directory, gatewayToken, impToken])]: () =>
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
  const path = `${state.scenario.directory}/gateway-token`;
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

function writeGatewayToken(state: HostState, rest: string) {
  if (state.scenario.writeError !== undefined) {
    return { exitCode: 1, stderr: `${state.scenario.writeError}\n` };
  }

  state.scenario.files['gateway-token'] = {
    // the script's `read` takes the line after it, and writes it back with a newline
    content: `${rest.split('\n')[0] ?? ''}\n`,
    mode: '400',
  };

  return {};
}

const mintGrantable = [
  // the host mint script's --grantable list, in its order
  'glm',
  'claude-setup-token',
  'github-imp-agents',
  'linear-imp-agents',
  'op-connect',
];

function createImpToken(state: HostState) {
  if (state.scenario.mintError !== undefined) {
    return { exitCode: 1, stderr: `${state.scenario.mintError}\n` };
  }

  const missing = mintGrantable.find(
    (name) => !state.scenario.secrets.some((secret) => secret['name'] === name),
  );

  // impd's tokens.create fails with NOT_FOUND for a grantable name no secret has
  // (packages/daemon/src/auth/token-store.ts), and the CLI prints it as one line, exit 1
  if (missing !== undefined) {
    return { exitCode: 1, stderr: `impz: NOT_FOUND: secret ${missing} not found\n` };
  }

  state.scenario.tokens.push({
    name: 'atc-cloud',
    scope: 'manage',
    imps: ['harness-*'],
    sshKeys: [],
    grantable: [
      'claude-setup-token',
      'github-imp-agents',
      'glm',
      'linear-imp-agents',
      'op-connect',
    ],
    createdAt: '2026-10-07T12:00:00.000Z',
  });

  const minted = state.scenario.minted ?? 'imp_fixture_minted_token\n';
  const notice = 'impz: token atc-cloud made; impd shows its secret only this once\n';

  // the host script saves only a mint of exactly one line
  if (minted.split('\n').length !== 2) {
    return { exitCode: 1, stderr: notice };
  }

  state.scenario.files['imp-token'] = { content: minted, mode: '400' };

  // imp 1.0.0 prints the new token's secret alone on stdout, after its notice on stderr
  // (packages/cli/src/commands/tokens.ts)
  return { stderr: notice };
}

function checkTokenFile(state: HostState): StubAnswer {
  if (state.scenario.files['imp-token'] === undefined) {
    return { exitCode: 120 };
  }

  // what imp's CLI prints for `token whoami --json` (packages/cli/src/commands/tokens.ts)
  return state.scenario.tokenCheck ?? { stdout: '{"kind":"token","name":"atc-cloud"}\n' };
}

function buildStatAnswer(state: HostState): StubAnswer {
  const gone = new Set(state.scenario.goneBeforeStat);

  const found = ['gateway-token', 'imp-token'].map((name) => {
    const file = gone.has(name) ? undefined : state.scenario.files[name];
    const path = `${state.scenario.directory}/${name}`;

    return file === undefined
      ? { error: `stat: cannot statx '${path}': No such file or directory\n` }
      : { line: `${path} root ${file.mode} ${Buffer.byteLength(file.content)} bytes\n` };
  });

  const lines = found.map((entry) => entry.line ?? '').join('');
  const errors = found.map((entry) => entry.error ?? '').join('');

  return {
    exitCode: errors === '' ? 0 : 1,
    stdout: `${state.scenario.directory} root 700 4096 bytes\n${lines}`,
    stderr: errors,
  };
}
