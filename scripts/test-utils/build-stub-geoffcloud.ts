// the stand-in's sandboxes are a mutable set by design
/* oxlint-disable typescript/prefer-readonly-parameter-types */
// Stands in for root's shell on geoffcloud at the fetch sandbox check's commands. It runs no probe:
// a probe of an address the scenario lets that side reach prints `probe-exit:0`, and any other
// times out with 124, as a dropped connection does. It tracks the sandboxes imp creates.
export interface StubGeoffcloudScenario {
  // nixie's sandbox manifest, as the pod holds it
  readonly manifest: string;
  readonly impdAddresses: readonly string[];
  readonly nodeAddresses: readonly string[];
  readonly podAddress: string;
  readonly serviceAddress: string;

  // each `<address>:<port>` the host's probe, and the sandbox's probe, connects to
  readonly hostReaches: readonly string[];
  readonly sandboxReaches: readonly string[];

  // what the sandbox's page fetch prints
  readonly page: string;

  // impz new's exit code
  readonly createExitCode: number;
}

interface RemoteResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

export interface StubGeoffcloud {
  readonly runRemote: (command: string) => Promise<RemoteResult>;

  // every command line, in order
  readonly commands: readonly string[];

  // the sandboxes that exist, by name
  readonly sandboxes: ReadonlySet<string>;
}

export function buildStubGeoffcloud(scenario: StubGeoffcloudScenario): StubGeoffcloud {
  const commands: string[] = [];

  const sandboxes = new Set<string>();

  return {
    runRemote: (command) => {
      commands.push(command);

      return Promise.resolve(buildAnswer({ scenario, sandboxes }, command));
    },
    commands,
    sandboxes,
  };
}

interface StubState {
  readonly scenario: StubGeoffcloudScenario;
  readonly sandboxes: Set<string>;
}

const reads: Record<string, (scenario: StubGeoffcloudScenario) => string> = {
  'k3s kubectl -n nixie exec nixie-0 -c nixie -- cat /app/sandbox-manifest.json': (scenario) =>
    scenario.manifest,
  'getent ahosts imps.geoff.cloud': (scenario) =>
    scenario.impdAddresses
      .flatMap((address) => [`${address} STREAM imps.geoff.cloud`, `${address} DGRAM`])
      .join('\n'),
  [`k3s kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address} {.items[*].status.addresses[?(@.type=="ExternalIP")].address}'`]:
    (scenario) => scenario.nodeAddresses.join(' '),
  'k3s kubectl -n nixie get pod nixie-0 -o jsonpath={.status.podIP}': (scenario) =>
    scenario.podAddress,
  'k3s kubectl -n nixie get service nixie -o jsonpath={.spec.clusterIP}': (scenario) =>
    scenario.serviceAddress,
};

// the probe as the host's shell gets it, and as it reaches the sandbox's bash through impz exec
const hostProbe =
  /^timeout 5 bash -c 'exec 3<>\/dev\/tcp\/(?<host>[^/]+)\/(?<port>\d+)' 2>\/dev\/null; echo probe-exit:\$\?$/u;

const sandboxProbe =
  /^docker exec imp-host impz exec \S+ -- bash -c 'timeout 5 bash -c '\\''exec 3<>\/dev\/tcp\/(?<host>[^/]+)\/(?<port>\d+)'\\'' 2>\/dev\/null; echo probe-exit:\$\?'$/u;

const pageFetch =
  /^docker exec imp-host impz exec \S+ -- bash -c '\/usr\/local\/bin\/bun -e '\\''const page = await fetch\("https:\/\/example\.com\/"\); .*'\\'''$/u;

function buildAnswer(state: StubState, command: string): RemoteResult {
  const read = reads[command];

  if (read !== undefined) {
    return { exitCode: 0, stdout: read(state.scenario), stderr: '' };
  }

  const imp = /^docker exec imp-host impz (?<verb>new|exec|rm) (?<name>\S+)/u.exec(command)?.groups;

  if (imp === undefined) {
    return buildProbeAnswer(state.scenario.hostReaches, hostProbe.exec(command)?.groups, command);
  }

  return buildImpAnswer(state, { verb: imp['verb'] ?? '', name: imp['name'] ?? '', command });
}

function buildProbeAnswer(
  reaches: readonly string[],
  probe: Readonly<Record<string, string>> | undefined,
  command: string,
): RemoteResult {
  if (probe === undefined) {
    return { exitCode: 97, stdout: '', stderr: `unexpected: ${command}` };
  }

  const reached = reaches.includes(`${probe['host']}:${probe['port']}`);

  return { exitCode: 0, stdout: `probe-exit:${reached ? 0 : 124}\n`, stderr: '' };
}

interface ImpCall {
  readonly verb: string;
  readonly name: string;
  readonly command: string;
}

function buildImpAnswer(state: StubState, call: ImpCall): RemoteResult {
  if (call.verb === 'new') {
    return buildCreateAnswer(state, call);
  }

  if (!state.sandboxes.has(call.name)) {
    return { exitCode: 1, stdout: '', stderr: `imp: no imp named ${call.name}\n` };
  }

  if (call.verb === 'rm') {
    state.sandboxes.delete(call.name);

    return { exitCode: 0, stdout: '', stderr: '' };
  }

  return pageFetch.test(call.command)
    ? { exitCode: 0, stdout: state.scenario.page, stderr: '' }
    : buildProbeAnswer(
        state.scenario.sandboxReaches,
        sandboxProbe.exec(call.command)?.groups,
        call.command,
      );
}

function buildCreateAnswer(state: StubState, call: ImpCall): RemoteResult {
  if (!/ --image nixie-fetch-[\da-f]{12} --policy public$/u.test(call.command)) {
    return { exitCode: 97, stdout: '', stderr: `unexpected: ${call.command}` };
  }

  if (state.scenario.createExitCode !== 0) {
    return {
      exitCode: state.scenario.createExitCode,
      stdout: '',
      stderr: 'imp: no image by that name\n',
    };
  }

  state.sandboxes.add(call.name);

  return { exitCode: 0, stdout: `${call.name} running\n`, stderr: '' };
}
