export interface StubGeoffcloudScenario {
  readonly manifest: string;
  readonly impdAddresses: readonly string[];
  readonly nodeAddresses: readonly string[];
  readonly podAddress: string;
  readonly serviceAddress: string;

  // each `<address>:<port>` the host's probe, and the sandbox's probe, connects to
  readonly hostReaches: readonly string[];
  readonly sandboxReaches: readonly string[];

  readonly page: string;

  readonly createExitCode: number;
}

interface RemoteResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

export interface StubGeoffcloud {
  readonly runRemote: (command: string) => Promise<RemoteResult>;

  readonly commands: readonly string[];

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
  'k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie sandbox-manifest': (scenario) =>
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

const hostProbe =
  /^timeout 5 bash -c 'exec 3<>\/dev\/tcp\/(?<host>[^/]+)\/(?<port>\d+)' 2>\/dev\/null; echo probe-exit:\$\?$/u;

function buildAnswer(state: StubState, command: string): RemoteResult {
  const stdoutOf = reads[command];

  if (stdoutOf !== undefined) {
    return { exitCode: 0, stdout: stdoutOf(state.scenario), stderr: '' };
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

  // an unreached address times out with 124, as a dropped connection does
  return { exitCode: 0, stdout: `probe-exit:${reached ? 0 : 124}\n`, stderr: '' };
}

interface ImpCall {
  readonly verb: string;
  readonly name: string;
  readonly command: string;
}

const sandboxProbe =
  /^docker exec imp-host impz exec \S+ -- bash -c 'timeout 5 bash -c '\\''exec 3<>\/dev\/tcp\/(?<host>[^/]+)\/(?<port>\d+)'\\'' 2>\/dev\/null; echo probe-exit:\$\?'$/u;

const pageFetch =
  /^docker exec imp-host impz exec \S+ -- bash -c '\/usr\/local\/bin\/bun -e '\\''const page = await fetch\("https:\/\/example\.com\/"\); .*'\\'''$/u;

function buildImpAnswer(state: StubState, call: ImpCall): RemoteResult {
  if (call.verb === 'new') {
    return buildCreateAnswer(state, call);
  }

  if (!state.sandboxes.has(call.name)) {
    return { exitCode: 1, stdout: '', stderr: `impz: no imp named ${call.name}\n` };
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
      stderr: 'impz: no image by that name\n',
    };
  }

  state.sandboxes.add(call.name);

  return { exitCode: 0, stdout: `${call.name} running\n`, stderr: '' };
}
