import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

// Stands in for ssh to the host that check-atc-gateway-readiness.ts inspects. It never runs a
// command: it reads the one quoted command line the script sends and answers as the host would.
export interface StubReadinessHostScenario {
  // the ssh destination it answers, such as root@geoffcloud; any other fails closed
  readonly destination: string;

  // every call fails as OpenSSH does when the host does not answer
  readonly isUnreachable?: boolean;

  // the row `kubectl get nodes --no-headers` prints
  readonly nodeLine: string;

  // free -m's available column, in MiB
  readonly availableMiB: number;
  readonly namespaces: readonly string[];
  readonly storageClasses: readonly string[];

  // each Deployment's readyReplicas, by <namespace>/<name>
  readonly deployments: Readonly<Record<string, number>>;
  readonly isDaemonActive: boolean;

  // what read-impd-health.sh prints: the status on its first line, and impd's body after it
  readonly impdHealth: string;

  // the status the probe pod's curl prints
  readonly probeCode: string;
}

export function buildStubReadinessHost(scenario: Readonly<StubReadinessHostScenario>): StubHandler {
  return (call) => (call.argv[0] === 'ssh' ? buildSSHAnswer(scenario, call) : undefined);
}

const sshOptions = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15'];

// OpenSSH 9.6p1's sshconnect.c error line, which log.c ends with CR LF, and its exit 255
function buildSSHAnswer(scenario: Readonly<StubReadinessHostScenario>, call: StubCall) {
  const [destination, command, ...rest] = call.argv.slice(sshOptions.length);
  const isShape = sshOptions.every((word, i) => call.argv[i] === word) && rest.length === 0;

  if (!isShape || destination !== scenario.destination || command === undefined) {
    return buildUnexpected(call);
  }

  if (scenario.isUnreachable === true) {
    const name = destination.replace(/^.*@/u, '');

    return {
      exitCode: 255,
      stderr: `ssh: connect to host ${name} port 22: Connection timed out\r\n`,
    };
  }

  return buildCommandAnswer(scenario, call, splitShellWords(command));
}

// The words of a command line that quotes each word whole in single quotes, with a quote inside
// one written as '\''; any other syntax is no command the script sends
function splitShellWords(command: string): readonly string[] | undefined {
  const word = String.raw`'(?:[^']|'\\'')*'`;

  if (!new RegExp(`^${word}(?: ${word})*$`, 'u').test(command)) {
    return undefined;
  }

  const words = command.match(new RegExp(word, 'gu')) ?? [];

  return words.map((quoted) => quoted.slice(1, -1).replaceAll(String.raw`'\''`, "'"));
}

type HostCommand = (
  scenario: Readonly<StubReadinessHostScenario>,
  words: readonly string[],
) => StubAnswer;

// kubectl v1.35.8's NotFound error and exit 1, and its default columns, from its source; the
// padding and AGE values are not from a real cluster
const hostCommands: readonly (readonly [string, HostCommand])[] = [
  ['k3s kubectl get nodes --no-headers', (scenario) => ({ stdout: `${scenario.nodeLine}\n` })],
  ['free -m', buildFreeAnswer],
  [
    'k3s kubectl get namespace *',
    (scenario, words) => findObject(scenario.namespaces, 'namespaces', words[4]),
  ],
  [
    'k3s kubectl get storageclass *',
    (scenario, words) =>
      findObject(scenario.storageClasses, 'storageclasses.storage.k8s.io', words[4]),
  ],
  [
    'k3s kubectl get -n * deploy *',
    (scenario, words) => buildDeployAnswer(scenario, words[4], words[6]),
  ],
  [
    'k3s kubectl -n * get deploy *',
    (scenario, words) => buildDeployAnswer(scenario, words[3], words[6]),
  ],
  [
    'k3s kubectl -n * get deploy * -o jsonpath={.status.readyReplicas}',
    (scenario, words) => buildReadyReplicasAnswer(scenario, words[3], words[6]),
  ],
  [
    'systemctl is-active --quiet atc-daemon',
    (scenario) => (scenario.isDaemonActive ? {} : { exitCode: 3 }),
  ],
  ['bash -s -- *', (scenario) => ({ stdout: scenario.impdHealth })],
  [
    'k3s kubectl -n atc run readiness-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.16.0 -- curl -s -o /dev/null -w %{http_code} -H * *',
    (scenario) => ({ stdout: scenario.probeCode }),
  ],
];

function buildCommandAnswer(
  scenario: Readonly<StubReadinessHostScenario>,
  call: StubCall,
  words: readonly string[] | undefined,
) {
  const command = hostCommands.find(([shape]) => isShapeOf(shape, words ?? []));

  return command === undefined || words === undefined
    ? buildUnexpected(call)
    : command[1](scenario, words);
}

function isShapeOf(shape: string, words: readonly string[]) {
  const parts = shape.split(' ');

  return (
    parts.length === words.length && parts.every((part, i) => part === '*' || part === words[i])
  );
}

// procps-ng's free -m layout, with the available column last
function buildFreeAnswer(scenario: Readonly<StubReadinessHostScenario>): StubAnswer {
  const mem = `Mem:            3915        1234         567          12        2113        ${scenario.availableMiB}`;

  return {
    stdout: `               total        used        free      shared  buff/cache   available\n${mem}\nSwap:              0           0           0\n`,
  };
}

function findObject(names: readonly string[], kind: string, name = ''): StubAnswer {
  return names.includes(name)
    ? { stdout: `NAME   STATUS   AGE\n${name}    Active   2d\n` }
    : buildNotFound(kind, name);
}

function buildDeployAnswer(
  scenario: Readonly<StubReadinessHostScenario>,
  namespace = '',
  name = '',
): StubAnswer {
  const ready = scenario.deployments[`${namespace}/${name}`];

  return ready === undefined
    ? buildNotFound('deployments.apps', name)
    : {
        stdout: `NAME   READY   UP-TO-DATE   AVAILABLE   AGE\n${name}   ${ready}/1     1            ${ready}           2d\n`,
      };
}

// jsonpath prints the value with no newline
function buildReadyReplicasAnswer(
  scenario: Readonly<StubReadinessHostScenario>,
  namespace = '',
  name = '',
): StubAnswer {
  const ready = scenario.deployments[`${namespace}/${name}`];

  return ready === undefined ? buildNotFound('deployments.apps', name) : { stdout: String(ready) };
}

function buildNotFound(kind: string, name: string): StubAnswer {
  return { exitCode: 1, stderr: `Error from server (NotFound): ${kind} "${name}" not found\n` };
}

function buildUnexpected(call: StubCall): StubAnswer {
  return { exitCode: 97, stderr: `unexpected: ${JSON.stringify(call.argv)}\n` };
}
