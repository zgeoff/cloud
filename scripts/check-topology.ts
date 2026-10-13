import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { topology } from '@zgeoff/cloud-topology';
import { findJSONField } from './find-json-field.ts';

// Compares each copy of a shared constant that stays outside packages/topology with the constant,
// and prints each mismatch with its file and field: 0 when every copy agrees, 1 on a mismatch or
// an unreadable file.
export interface CheckTopologyOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: check-topology.ts [repo root]\n';

export async function checkTopology(options: Readonly<CheckTopologyOptions>): Promise<number> {
  if (options.args.length > 1) {
    options.printErr(usage);

    return 2;
  }

  const root = options.args[0] ?? '.';

  const loaded = await Promise.all(sources.map((source) => loadCopies(root, source)));

  const unreadable = sources.filter((_, index) => loaded[index] === undefined);

  if (unreadable.length > 0) {
    options.printErr(
      unreadable.map((source) => `check-topology: cannot read ${source.file}\n`).join(''),
    );

    return 1;
  }

  return printReport(
    loaded.flatMap((copies) => copies ?? []),
    options,
  );
}

// one value that a file holds, and the value the constants give it
interface Copy {
  readonly file: string;
  readonly field: string;
  readonly actual: unknown;
  readonly expected: unknown;
}

// a file that holds copies, and the copies its parsed YAML holds
interface Source {
  readonly file: string;
  readonly collectCopies: (parsed: unknown) => readonly Omit<Copy, 'file'>[];
}

const daemonPort = topology.atc.daemonPort;
const gatewayDaemons = ['config', 'geoff-cloud:atcGateway', 'daemons'];

const sources: readonly Source[] = [
  // the stack config's daemon addresses, which the gateway's registry reads as config
  {
    file: 'infra/Pulumi.prod.yaml',
    collectCopies: (stack) => [
      {
        field: 'geoff-cloud:atcGateway.daemons.geoffcloud.address',
        actual: findPath(stack, [...gatewayDaemons, 'geoffcloud', 'address']),
        expected: `${topology.tailnet.nodes.geoffcloud.address}:${daemonPort}`,
      },
      {
        field: 'geoff-cloud:atcGateway.daemons.home-pc.address',
        actual: findPath(stack, [...gatewayDaemons, 'home-pc', 'address']),
        expected: `${topology.tailnet.nodes.homePC.address}:${daemonPort}`,
      },
    ],
  },

  // nixie's config file, which infra mounts byte for byte
  {
    file: 'deploy/nixie/config.yaml',
    collectCopies: (config) => [
      {
        field: 'imp.url',
        actual: findPath(config, ['imp', 'url']),
        expected: `https://${topology.imp.domain}`,
      },
      ...collectHostAddressCopies(findPath(config, ['imp', 'host_addresses'])),
      {
        field: 'imp.egress_deny',
        actual: findPath(config, ['imp', 'egress_deny']),
        expected: [topology.k3s.podCIDR, topology.k3s.serviceCIDR],
      },
    ],
  },

  // the deploy workflow, whose tailnet tag an action input takes as a literal
  {
    file: '.github/workflows/deploy-prod.yml',
    collectCopies: (workflow) =>
      collectTailscaleSteps(findJSONField(workflow, 'jobs')).map((step) => ({
        field: `jobs.${step.job}: tailscale/github-action's tags`,
        actual: step.tags,
        expected: topology.tailnet.tags.cloudDeploy,
      })),
  },
];

// undefined for a file it cannot read, so the check stops before it compares anything
async function loadCopies(root: string, source: Source): Promise<readonly Copy[] | undefined> {
  const text = await readFile(join(root, source.file), 'utf8').catch(() => null);

  if (text === null) {
    return undefined;
  }

  return source.collectCopies(parseYAML(text)).map((copy) => ({
    file: source.file,
    field: copy.field,
    actual: copy.actual,
    expected: copy.expected,
  }));
}

function parseYAML(text: string): unknown {
  try {
    const parsed: unknown = Bun.YAML.parse(text);

    return parsed;
  } catch {
    return undefined;
  }
}

function findPath(value: unknown, keys: readonly string[]): unknown {
  return keys.reduce((field: unknown, key) => findJSONField(field, key), value);
}

// impd's IMP_HOST_ADDRESSES, each with its interface's prefix length, which the host config holds;
// the constants hold the addresses
function collectHostAddressCopies(entries: unknown): readonly Omit<Copy, 'file'>[] {
  const expected = [
    topology.vm.publicIPv4,
    topology.vm.publicIPv6,
    topology.docker.bridgeAddress,
    topology.tailnet.nodes.geoffcloud.address,
  ];

  return expected.map((address, index) => {
    const entry: unknown = Array.isArray(entries) ? entries[index] : undefined;

    return {
      field: `imp.host_addresses[${index}]`,
      actual: typeof entry === 'string' ? entry.split('/')[0] : entry,
      expected: address,
    };
  });
}

interface TailscaleStep {
  readonly job: string;
  readonly tags: unknown;
}

// each tailscale/github-action step, by its job, with the tags it joins as
function collectTailscaleSteps(jobs: unknown): readonly TailscaleStep[] {
  if (typeof jobs !== 'object' || jobs === null) {
    return [];
  }

  return Object.entries(jobs).flatMap((entry: readonly [string, unknown]) => {
    const steps = findJSONField(entry[1], 'steps');
    const list: readonly unknown[] = Array.isArray(steps) ? steps : [];
    const tailscaleSteps = list.filter((step: unknown) => isTailscaleStep(step));

    return tailscaleSteps.map((step: unknown) => ({
      job: entry[0],
      tags: findPath(step, ['with', 'tags']),
    }));
  });
}

function isTailscaleStep(step: unknown): boolean {
  const uses = findJSONField(step, 'uses');

  return typeof uses === 'string' && uses.startsWith('tailscale/github-action@');
}

function printReport(copies: readonly Copy[], options: Readonly<CheckTopologyOptions>): number {
  const mismatches = copies.filter((copy) => !Bun.deepEquals(copy.actual, copy.expected));

  if (mismatches.length > 0) {
    options.printErr(mismatches.map((copy) => formatMismatch(copy)).join(''));

    return 1;
  }

  options.printOut(`check-topology: ${copies.length} copies agree with packages/topology\n`);

  return 0;
}

function formatMismatch(copy: Copy): string {
  const actual = JSON.stringify(copy.actual) ?? 'nothing';
  const expected = JSON.stringify(copy.expected);

  return `check-topology: ${copy.file}: ${copy.field} is ${actual}, but packages/topology gives ${expected}\n`;
}

if (import.meta.main) {
  process.exitCode = await checkTopology({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
