import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import invariant from 'tiny-invariant';
import { runPulumiPreview } from '../test-utils/run-pulumi-preview.ts';

// Each case previews the fixture program through the real Pulumi engine and the Kubernetes
// provider's Helm renderer, with a local state backend and no cluster. Bun 1.4.2's skipIf takes a
// boolean, so the probe for the Pulumi CLI runs at collection; CI installs the CLI and its plugin.
const pulumiPath = Bun.which('pulumi');

async function setupTest() {
  invariant(pulumiPath !== null, 'the Pulumi CLI is not on PATH');

  // the stack stops a preview still running at the timeout before it removes the directory
  const stack = new AsyncDisposableStack();

  onTestFinished(() => stack.disposeAsync());

  const dir = await mkdtemp(join(tmpdir(), 'port-forward-guard-'));

  stack.defer(() => rm(dir, { recursive: true, force: true }));

  const caseDir = join(dir, 'case');

  await mkdir(join(dir, 'state'));
  await mkdir(caseDir);

  await writeFile(
    join(dir, 'Pulumi.yaml'),
    [
      'name: port-forward-guard',
      'runtime: bun',
      `main: ${join(import.meta.dir, '..', 'test-utils', 'port-forward-guard-program', 'index.ts')}`,
      '',
    ].join('\n'),
  );

  const env = {
    PATH: [dirname(pulumiPath), dirname(process.execPath), '/usr/bin', '/bin'].join(':'),
    HOME: homedir(),
    PULUMI_BACKEND_URL: `file://${join(dir, 'state')}`,
    PULUMI_CONFIG_PASSPHRASE: 'port-forward-guard',
    PULUMI_SKIP_UPDATE_CHECK: 'true',
    PULUMI_DISABLE_AUTOMATIC_PLUGIN_ACQUISITION: 'true',
    GUARD_CASE_DIR: caseDir,
  };

  const init = Bun.spawnSync([pulumiPath, 'stack', 'init', 'test', '--non-interactive'], {
    cwd: dir,
    env,
  });

  invariant(init.exitCode === 0, `pulumi stack init failed: ${init.stderr.toString()}`);

  const runPreview = () => runPulumiPreview({ pulumiPath, cwd: dir, env, cleanup: stack });

  return { caseDir, runPreview };
}

test.skipIf(pulumiPath === null).each([
  [
    "a Helm chart's Role that creates pods/portforward",
    'chart/templates/rbac.yaml',
    [
      'apiVersion: rbac.authorization.k8s.io/v1',
      'kind: Role',
      'metadata:',
      '  name: forward',
      'rules:',
      '  - apiGroups: [""]',
      '    resources: ["pods/portforward"]',
      '    verbs: ["create"]',
    ].join('\n'),
    'kubernetes:rbac.authorization.k8s.io/v1:Role has a rule that covers pods/portforward',
  ],
  [
    "a Helm chart's ClusterRole with every verb on every resource",
    'chart/templates/rbac.yaml',
    [
      'apiVersion: rbac.authorization.k8s.io/v1',
      'kind: ClusterRole',
      'metadata:',
      '  name: everything',
      'rules:',
      '  - apiGroups: ["*"]',
      '    resources: ["*"]',
      '    verbs: ["*"]',
    ].join('\n'),
    'kubernetes:rbac.authorization.k8s.io/v1:ClusterRole has a rule that covers pods/portforward',
  ],
  [
    'a raw Kubernetes Role that creates pods/portforward',
    'roles.json',
    JSON.stringify([
      {
        metadata: { name: 'forward', namespace: 'atc' },
        rules: [{ apiGroups: [''], resources: ['pods/portforward'], verbs: ['create'] }],
      },
    ]),
    'kubernetes:rbac.authorization.k8s.io/v1:Role has a rule that covers pods/portforward',
  ],
])(
  'it fails the preview of %s',
  async (_label: string, path: string, content: string, reason: string) => {
    const ctx = await setupTest();

    await mkdir(join(ctx.caseDir, 'chart', 'templates'), { recursive: true });

    await writeFile(
      join(ctx.caseDir, 'chart', 'Chart.yaml'),
      'apiVersion: v2\nname: case\nversion: 0.1.0\n',
    );

    await writeFile(join(ctx.caseDir, path), content);

    const result = await ctx.runPreview();

    expect(result.exitCode).toBe(1);

    expect(result.output).toInclude(
      `transform failed: Error: ${reason}; no RBAC object may grant pods/portforward`,
    );
  },
  120_000,
);

test.skipIf(pulumiPath === null)(
  "it passes the preview of a Helm chart's Role and a raw Role that read pods",
  async () => {
    const ctx = await setupTest();

    await mkdir(join(ctx.caseDir, 'chart', 'templates'), { recursive: true });

    await writeFile(
      join(ctx.caseDir, 'chart', 'Chart.yaml'),
      'apiVersion: v2\nname: case\nversion: 0.1.0\n',
    );

    await writeFile(
      join(ctx.caseDir, 'chart', 'templates', 'rbac.yaml'),
      [
        'apiVersion: rbac.authorization.k8s.io/v1',
        'kind: Role',
        'metadata:',
        '  name: read',
        'rules:',
        '  - apiGroups: [""]',
        '    resources: ["pods", "pods/log"]',
        '    verbs: ["get", "list", "watch"]',
      ].join('\n'),
    );

    await writeFile(
      join(ctx.caseDir, 'roles.json'),
      JSON.stringify([
        {
          metadata: { name: 'read', namespace: 'atc' },
          rules: [{ apiGroups: [''], resources: ['pods'], verbs: ['get'] }],
        },
      ]),
    );

    const result = await ctx.runPreview();

    expect(result.exitCode).toBe(0);
  },
  120_000,
);
