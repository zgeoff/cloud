import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { z } from 'zod';
import { atcGatewayConfigSchema } from '../inputs/index.ts';
import { buildATCGatewayBackupPodSpec } from './build-atc-gateway-backup-pod-spec.ts';
import { buildFilesBackupPodSpec } from './build-files-backup-pod-spec.ts';
import { ghcrPullSecretName } from './build-ghcr-pull-secret-args.ts';
import { buildNixieRestorePodSpec } from './build-nixie-restore-pod-spec.ts';
import { buildRestoreJob } from './build-restore-job.ts';
import { toRestorePod } from './to-restore-pod.ts';

export interface WriteRestoreJobsOptions {
  readonly args: readonly string[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;

  readonly formatter?: string;
}

const usage = 'usage: write-restore-jobs.ts [--check] [repo root]\n';
const stackFile = join('infra', 'Pulumi.prod.yaml');

// the repo root, where oxfmt and its config live
const repoDir = join(import.meta.dir, '..', '..');
const repoFormatter = join(repoDir, 'node_modules', '.bin', 'oxfmt');

export function writeRestoreJobs(options: Readonly<WriteRestoreJobsOptions>): Promise<number> {
  const parsed = parseArgs(options.args);

  if (parsed === undefined) {
    options.printErr(usage);

    return Promise.resolve(2);
  }

  return applyRestoreJobs(parsed, options);
}

interface RestoreJobsArgs {
  readonly check: boolean;
  readonly root: string;
}

function parseArgs(args: readonly string[]): RestoreJobsArgs | undefined {
  const check = args[0] === '--check';
  const rest = check ? args.slice(1) : args;

  return rest.length > 1 || rest[0]?.startsWith('-') === true
    ? undefined
    : { check, root: rest[0] ?? '.' };
}

async function applyRestoreJobs(
  parsed: RestoreJobsArgs,
  options: Readonly<WriteRestoreJobsOptions>,
): Promise<number> {
  const backupImage = await loadBackupImage(parsed.root);

  if (typeof backupImage !== 'string') {
    options.printErr(`write-restore-jobs: ${backupImage.error}\n`);

    return 1;
  }

  const outcomes = await Promise.all(
    buildRestoreJobFiles(backupImage).map((job) =>
      applyRestoreJob({
        root: parsed.root,
        check: parsed.check,
        job,
        formatter: options.formatter ?? repoFormatter,
      }),
    ),
  );

  printOutcomes(outcomes, options);

  return Math.max(0, ...outcomes.map((outcome) => outcome.status));
}

const stackSchema = z.object({ config: z.object({ 'geoff-cloud:atcGateway': z.unknown() }) });

async function loadBackupImage(root: string): Promise<string | { readonly error: string }> {
  const text = await readFile(join(root, stackFile), 'utf8').catch(() => null);

  if (text === null) {
    return { error: `cannot read ${stackFile}` };
  }

  const stack = stackSchema.safeParse(parseYAML(text));

  if (!stack.success) {
    return { error: `${stackFile} sets no geoff-cloud:atcGateway` };
  }

  const config = atcGatewayConfigSchema.safeParse(stack.data.config['geoff-cloud:atcGateway']);

  return config.success
    ? config.data.backupImage
    : { error: `${stackFile}'s geoff-cloud:atcGateway: ${z.prettifyError(config.error)}` };
}

function parseYAML(text: string): unknown {
  try {
    const parsed: unknown = Bun.YAML.parse(text);

    return parsed;
  } catch {
    return undefined;
  }
}

interface RestoreJobFile {
  readonly path: string;
  readonly header: string;
  readonly job: unknown;
}

// each name must match the one its backup CronJob's claim, Secret or ConfigMap gets in the cluster
function buildRestoreJobFiles(backupImage: string): readonly RestoreJobFile[] {
  return [
    {
      path: join('images', 'atc-gateway', 'restore-job.yaml'),
      header: `${renderGeneratedNote('backup pod', 'infra/cluster/build-atc-gateway-backup-pod-spec.ts')}# One-off restore of the atc gateway's state. Stop the gateway first
# (docs/runbooks/atc-gateway-backup-restore.md), then:
#   ssh root@geoffcloud k3s kubectl create -f - < images/atc-gateway/restore-job.yaml
# To list the snapshots instead, set args to ['ls']; to restore another snapshot, set SNAPSHOT.
`,
      job: buildRestoreJob({
        name: 'atc-gateway',
        namespace: 'atc',
        pod: toRestorePod(
          buildATCGatewayBackupPodSpec({
            image: backupImage,
            claim: 'atc-gateway-state',
            envSecret: 'atc-gateway-backup',
            pullSecret: ghcrPullSecretName,
          }),
        ),
      }),
    },
    {
      path: join('deploy', 'nixie', 'restore-job.yaml'),
      header: `${renderGeneratedNote('restore pod', 'infra/cluster/build-nixie-restore-pod-spec.ts')}# One-off restore of nixie's data, from the nixie-backup CronJob's repository: restic restores the
# snapshot, and nixie's own restore command replaces nixie.db and keys.db with it. Stop nixie first
# and create the Job with nixie's image in place of NIXIE_IMAGE (docs/runbooks/nixie-backup.md).
# To list the snapshots instead, set the fetch container's args to ['ls'], and nixie's restore then
# finds no backup and changes nothing; to restore another snapshot, set SNAPSHOT. The claim is
# data-nixie-0, nixie's own; the restore test swaps in its scratch claim, nixie-restore-check. The
# script, nixie's config and the Secret come from the CronJob's fixed-name ConfigMaps and Secret.
`,
      job: buildRestoreJob({
        name: 'nixie',
        namespace: 'nixie',
        pod: buildNixieRestorePodSpec({
          image: backupImage,
          nixieImage: 'NIXIE_IMAGE',
          claim: 'data-nixie-0',
          scriptConfigMap: 'nixie-backup-script',
          configMap: 'nixie-backup-config',
          envSecret: 'nixie-backup',
          pullSecret: ghcrPullSecretName,
        }),
      }),
    },
    {
      path: join('deploy', 'files', 'restore-job.yaml'),
      header: `${renderGeneratedNote('backup pod', 'infra/cluster/build-files-backup-pod-spec.ts')}# One-off restore of the files service's volume, from the files-backup CronJob's repository. Stop
# the service first (docs/runbooks/files.md), then:
#   ssh root@geoffcloud k3s kubectl create -f - < deploy/files/restore-job.yaml
# To list the snapshots instead, set args to ['ls']; to restore another snapshot, set SNAPSHOT. The
# claim is data-files-0, the service's own. The script and the Secret come from the CronJob's
# fixed-name ConfigMap and Secret.
`,
      job: buildRestoreJob({
        name: 'files',
        namespace: 'files',
        pod: toRestorePod(
          buildFilesBackupPodSpec({
            image: backupImage,
            claim: 'data-files-0',
            scriptConfigMap: 'files-backup-script',
            envSecret: 'files-backup',
            pullSecret: ghcrPullSecretName,
          }),
        ),
      }),
    },
  ];
}

function renderGeneratedNote(pod: 'backup pod' | 'restore pod', builder: string): string {
  return `# Generated by \`bun run write:restore-job\` from the ${pod} in
# ${builder} and the stack config's atcGateway.backupImage: never
# edit it by hand. \`bun run check:restore-job\` fails when it differs.
#
`;
}

interface RestoreJobChange {
  readonly root: string;
  readonly check: boolean;
  readonly job: RestoreJobFile;
  readonly formatter: string;
}

interface RestoreJobOutcome {
  readonly status: number;
  readonly line?: string;
}

async function applyRestoreJob(change: RestoreJobChange): Promise<RestoreJobOutcome> {
  const written = await tryRunRestoreJobFormatter(change.job, change.formatter);

  if (typeof written !== 'string') {
    return { status: 1, line: `write-restore-jobs: ${written.error}\n` };
  }

  const current = await readFile(join(change.root, change.job.path), 'utf8').catch(() => null);

  if (current === written) {
    return { status: 0 };
  }

  if (change.check) {
    return {
      status: 1,
      line: `write-restore-jobs: ${change.job.path} differs from its builder's output; run bun run write:restore-job\n`,
    };
  }

  await writeFile(join(change.root, change.job.path), written);

  return { status: 0, line: `write-restore-jobs: wrote ${change.job.path}\n` };
}

async function tryRunRestoreJobFormatter(
  job: RestoreJobFile,
  formatter: string,
): Promise<string | { readonly error: string }> {
  try {
    return await runRestoreJobFormatter(job, formatter);
  } catch (error) {
    return {
      error: `cannot format ${job.path}: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

// the repo's own oxfmt lays the file out, so format:check leaves the written file as it is
async function runRestoreJobFormatter(job: RestoreJobFile, formatterPath: string): Promise<string> {
  const formatter = Bun.spawn([formatterPath, `--stdin-filepath=${job.path}`], {
    cwd: repoDir,
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  await formatter.stdin.write(`${job.header}${Bun.YAML.stringify(job.job, null, 2)}\n`);
  await formatter.stdin.end();

  const [text, error, status] = await Promise.all([
    new Response(formatter.stdout).text(),
    new Response(formatter.stderr).text(),
    formatter.exited,
  ]);

  if (status !== 0) {
    throw new Error(`oxfmt exited ${status}: ${error.trim()}`);
  }

  return text;
}

function printOutcomes(
  outcomes: readonly RestoreJobOutcome[],
  options: Readonly<WriteRestoreJobsOptions>,
): void {
  for (const outcome of outcomes) {
    if (outcome.line !== undefined) {
      (outcome.status === 0 ? options.printOut : options.printErr)(outcome.line);
    }
  }
}

if (import.meta.main) {
  process.exitCode = await writeRestoreJobs({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
