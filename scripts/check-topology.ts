import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Topology } from '@zgeoff/cloud-topology';
import { topology } from '@zgeoff/cloud-topology';
import { z } from 'zod';

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

  const failures = loaded.flatMap((result) => ('error' in result ? [result.error] : []));

  if (failures.length > 0) {
    options.printErr(failures.map((failure) => `check-topology: ${failure}\n`).join(''));

    return 1;
  }

  return printReport(
    loaded.flatMap((result) => ('copies' in result ? result.copies : [])),
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

type LoadResult = { readonly copies: readonly Copy[] } | { readonly error: string };

// a file that holds copies, with its parse and its copies' reader bound together, so files of
// different shapes share one list
interface CopySource {
  readonly file: string;
  readonly collectCopies: (parsed: unknown) => LoadResult;
}

interface Source<T> {
  readonly file: string;
  readonly schema: z.ZodType<T>;
  readonly collectCopies: (parsed: T, constants: Topology) => readonly Omit<Copy, 'file'>[];
}

// The stack config's daemon addresses, which the gateway's registry reads as config
const stackDaemonSchema = z.looseObject({ address: z.string() });

const stackDaemonsSchema = z.looseObject({
  geoffcloud: stackDaemonSchema,
  'home-pc': stackDaemonSchema,
});

const stackGatewaySchema = z.looseObject({ daemons: stackDaemonsSchema });

const stackSchema = z.looseObject({
  config: z.looseObject({ 'geoff-cloud:atcGateway': stackGatewaySchema }),
});

// nixie's config file, which infra mounts byte for byte
const nixieImpSchema = z.looseObject({
  url: z.string(),
  host_addresses: z.array(z.string()),
  egress_deny: z.array(z.string()),
});

const nixieConfigSchema = z.looseObject({ imp: nixieImpSchema });

// the deploy workflow, whose tailnet tag an action input takes as a literal
const workflowStepWithSchema = z.looseObject({ tags: z.string().optional() });

const workflowStepSchema = z.looseObject({
  uses: z.string().optional(),
  with: workflowStepWithSchema.optional(),
});

const workflowJobSchema = z.looseObject({ steps: z.array(workflowStepSchema).optional() });
const workflowSchema = z.looseObject({ jobs: z.record(z.string(), workflowJobSchema) });

type Workflow = z.infer<typeof workflowSchema>;

const sources: readonly CopySource[] = [
  defineSource({
    file: 'infra/Pulumi.prod.yaml',
    schema: stackSchema,
    collectCopies: (stack, constants) => {
      const daemons = stack.config['geoff-cloud:atcGateway'].daemons;
      const port = constants.atc.daemonPort;

      return [
        {
          field: 'geoff-cloud:atcGateway.daemons.geoffcloud.address',
          actual: daemons.geoffcloud.address,
          expected: `${constants.tailnet.nodes.geoffcloud.address}:${port}`,
        },
        {
          field: 'geoff-cloud:atcGateway.daemons.home-pc.address',
          actual: daemons['home-pc'].address,
          expected: `${constants.tailnet.nodes.homePC.address}:${port}`,
        },
      ];
    },
  }),
  defineSource({
    file: 'deploy/nixie/config.yaml',
    schema: nixieConfigSchema,
    collectCopies: (config, constants) => {
      // impd's IMP_HOST_ADDRESSES, each with its interface's prefix length, which the host config
      // holds; the constants hold the addresses
      const addresses = config.imp.host_addresses.map((entry) => entry.split('/')[0]);

      const expectedAddresses = [
        constants.vm.publicIPv4,
        constants.vm.publicIPv6,
        constants.docker.bridgeAddress,
        constants.tailnet.nodes.geoffcloud.address,
      ];

      return [
        { field: 'imp.url', actual: config.imp.url, expected: `https://${constants.imp.domain}` },
        ...expectedAddresses.map((expected, index) => ({
          field: `imp.host_addresses[${index}]`,
          actual: addresses[index],
          expected,
        })),
        {
          field: 'imp.egress_deny',
          actual: config.imp.egress_deny,
          expected: [constants.k3s.podCIDR, constants.k3s.serviceCIDR],
        },
      ];
    },
  }),
  defineSource({
    file: '.github/workflows/deploy-prod.yml',
    schema: workflowSchema,
    collectCopies: (workflow, constants) =>
      collectTailscaleSteps(workflow).map((step) => ({
        field: `jobs.${step.job}: tailscale/github-action's tags`,
        actual: step.tags,
        expected: constants.tailnet.tags.cloudDeploy,
      })),
  }),
];

function defineSource<T>(source: Source<T>): CopySource {
  return {
    file: source.file,
    collectCopies: (value) => {
      const parsed = source.schema.safeParse(value);

      if (!parsed.success) {
        const paths = parsed.error.issues.map((issue) => issue.path.join('.'));

        return { error: `${source.file} lacks the fields it checks: ${paths.join(', ')}` };
      }

      const copies = source.collectCopies(parsed.data, topology);

      return {
        copies: copies.map((copy) => ({
          file: source.file,
          field: copy.field,
          actual: copy.actual,
          expected: copy.expected,
        })),
      };
    },
  };
}

// each tailscale/github-action step, by its job, with the tags it joins as
function collectTailscaleSteps(
  workflow: Workflow,
): readonly { readonly job: string; readonly tags: string | undefined }[] {
  return Object.entries(workflow.jobs).flatMap(([job, definition]) => {
    const steps = definition.steps ?? [];

    const tailscaleSteps = steps.filter(
      (step) => step.uses?.startsWith('tailscale/github-action@') === true,
    );

    return tailscaleSteps.map((step) => ({ job, tags: step.with?.tags }));
  });
}

async function loadCopies(root: string, source: CopySource): Promise<LoadResult> {
  const text = await readFile(join(root, source.file), 'utf8').catch(() => null);

  if (text === null) {
    return { error: `cannot read ${source.file}` };
  }

  return source.collectCopies(parseYAML(text));
}

function parseYAML(text: string): unknown {
  try {
    const parsed: unknown = Bun.YAML.parse(text);

    return parsed;
  } catch {
    return undefined;
  }
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
