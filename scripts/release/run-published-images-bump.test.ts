import { expect, mock, test } from 'bun:test';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubReleaseDocker } from '../test-utils/build-stub-release-docker.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createCloudCheckout } from '../test-utils/create-cloud-checkout.ts';
import { runPublishedImagesBump } from './run-published-images-bump.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it opens a gateway minor bump that merges on its own, at the digests the run published', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.2.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
    'infra/Pulumi.prod.yaml': `config:\n  geoff-cloud:atcGateway:\n    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/atc-gateway:7.2.0': `sha256:${'3'.repeat(64)}`,
      'ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1': `sha256:${'2'.repeat(64)}`,
    },
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: {} }),
    docker.handle,
    buildRealProgramHandler(['git'], checkout.env),
  );

  const env = {
    ...checkout.env,
    GITHUB_SERVER_URL: 'https://github.com',
    GITHUB_REPOSITORY: 'zgeoff/cloud',
    GITHUB_RUN_ID: '4417',
  };

  const status = await runPublishedImagesBump({ cwd: checkout.clone, env, run: stub.run, ...ctx }, [
    'atc-gateway-images',
  ]);

  const diff = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'diff',
    'main',
    'release-check/atc-gateway-images',
    '--',
    'infra/Pulumi.prod.yaml',
  ]);

  const table = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'show',
    'release-check/atc-gateway-images:scripts/release/release-pins.json',
  ]);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    [
      `pinned atc-gateway-image 7.2.0\natc-gateway-backup-image already pins 3.1.0-r1 sha256:${'2'.repeat(64)}\n`,
    ],
    ['https://github.com/zgeoff/cloud/pull/200\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(diff.split('\n').filter((line) => /^[-+] /u.test(line))).toStrictEqual([
    `-    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}`,
    `+    image: ghcr.io/zgeoff/atc-gateway:7.2.0@sha256:${'3'.repeat(64)}`,
  ]);

  expect(JSON.parse(table)).toStrictEqual({
    'atc-gateway-image': { version: '7.2.0', digest: `sha256:${'3'.repeat(64)}` },
    'atc-gateway-backup-image': { tag: '3.1.0-r1', digest: `sha256:${'2'.repeat(64)}` },
  });

  expect(
    stub.calls
      .filter((call) => call.argv[0] !== 'git')
      .map((call) => [call.argv.join(' '), call.stdin]),
  ).toStrictEqual([
    [
      'docker buildx imagetools inspect ghcr.io/zgeoff/atc-gateway:7.2.0 --format {{json .Manifest}}',
      '',
    ],
    [
      'docker buildx imagetools inspect ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1 --format {{json .Manifest}}',
      '',
    ],
    [
      'gh pr list --repo zgeoff/cloud --head release-check/atc-gateway-images --state open --json number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      '',
    ],
    [
      'gh label create update:minor --repo zgeoff/cloud --force --color fbca04 --description a minor release',
      '',
    ],
    [
      'gh label create auto-merge --repo zgeoff/cloud --force --color 0e8a16 --description merges on its own once its checks pass',
      '',
    ],
    [
      'gh pr create --repo zgeoff/cloud --base main --head release-check/atc-gateway-images --title chore(atc-gateway-images): bump atc-gateway-images to 7.2.0+3.1.0-r1 --body-file - --label update:minor,auto-merge',
      `Pins the atc-gateway-images at [7.2.0](https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%407.2.0) to the digests [its run](https://github.com/zgeoff/cloud/actions/runs/4417) published. The publish workflow opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the atc-gateway image (\`infra/Pulumi.prod.yaml\`) | 7.1.0 | 7.2.0 |\n| the atc-gateway backup image (\`infra/Pulumi.prod.yaml\`) | 3.1.0-r1 | unchanged |\n\nIt merges on its own once every check on its head passes.\n\nAfter the merge: The \`Deploy prod\` workflow applies the stack config once CI passes on main, unless its guard holds the plan (\`docs/runbooks/prod-apply.md\`). For an atc major release, switch the host after the gateway runs it (\`docs/runbooks/workflows.md\`).\n`,
    ],
  ]);
});

test('it opens a gateway major bump that waits for review', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=8.0.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/atc-gateway:8.0.0': `sha256:${'3'.repeat(64)}`,
      'ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1': `sha256:${'2'.repeat(64)}`,
    },
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: {} }),
    docker.handle,
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runPublishedImagesBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc-gateway-images'],
  );

  expect(status).toBe(0);

  expect(stub.calls.map((call) => call.argv.join(' ')).at(-1)).toBe(
    'gh pr create --repo zgeoff/cloud --base main --head release-check/atc-gateway-images --title chore(atc-gateway-images): bump atc-gateway-images to 8.0.0+3.1.0-r1 --body-file - --label update:major,needs-review',
  );

  expect(stub.calls.at(-1)?.stdin).toBe(
    `Pins the atc-gateway-images at [8.0.0](https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%408.0.0) to the digests the publish workflow published. The publish workflow opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the atc-gateway image (\`infra/Pulumi.prod.yaml\`) | 7.1.0 | 8.0.0 |\n| the atc-gateway backup image (\`infra/Pulumi.prod.yaml\`) | 3.1.0-r1 | unchanged |\n\nIt waits for a review, because:\n\n- it is a major release.\n\nAfter the merge: The \`Deploy prod\` workflow applies the stack config once CI passes on main, unless its guard holds the plan (\`docs/runbooks/prod-apply.md\`). For an atc major release, switch the host after the gateway runs it (\`docs/runbooks/workflows.md\`).\n`,
  );
});

test('it opens a backup image bump that waits for review, since no release version moves', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.1.0\nBACKUP_IMAGE_TAG=3.1.0-r2\n',
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/atc-gateway:7.1.0': `sha256:${'1'.repeat(64)}`,
      'ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r2': `sha256:${'4'.repeat(64)}`,
    },
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: {} }),
    docker.handle,
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runPublishedImagesBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc-gateway-images'],
  );

  const diff = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'diff',
    'main',
    'release-check/atc-gateway-images',
    '--',
    'infra/Pulumi.prod.yaml',
  ]);

  expect(status).toBe(0);

  expect(diff.split('\n').filter((line) => /^[-+] /u.test(line))).toStrictEqual([
    `-    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}`,
    `+    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r2@sha256:${'4'.repeat(64)}`,
  ]);

  expect(stub.calls.map((call) => call.argv.join(' ')).at(-1)).toBe(
    'gh pr create --repo zgeoff/cloud --base main --head release-check/atc-gateway-images --title chore(atc-gateway-images): bump atc-gateway-images to 7.1.0+3.1.0-r2 --body-file - --label needs-review',
  );

  expect(stub.calls.at(-1)?.stdin).toBe(
    `Pins the atc-gateway-images at [7.1.0](https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%407.1.0) to the digests the publish workflow published. The publish workflow opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the atc-gateway image (\`infra/Pulumi.prod.yaml\`) | 7.1.0 | unchanged |\n| the atc-gateway backup image (\`infra/Pulumi.prod.yaml\`) | 3.1.0-r1 | 3.1.0-r2 |\n\nIt waits for a review, because:\n\n- it moves no release version, so no update type rates the change.\n\nAfter the merge: The \`Deploy prod\` workflow applies the stack config once CI passes on main, unless its guard holds the plan (\`docs/runbooks/prod-apply.md\`). For an atc major release, switch the host after the gateway runs it (\`docs/runbooks/workflows.md\`).\n`,
  );
});

test('it opens a new backup revision after a person closed the one before it', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.1.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  await checkout.git(['-C', checkout.seed, 'switch', '-qc', 'release-check/atc-gateway-images']);

  await Bun.write(
    `${checkout.seed}/infra/Pulumi.prod.yaml`,
    `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r2@sha256:${'4'.repeat(64)}\n`,
  );

  await checkout.git([
    '-C',
    checkout.seed,
    'commit',
    '-qam',
    'chore(atc-gateway-images): bump atc-gateway-images to 7.1.0+3.1.0-r2',
  ]);

  await checkout.git([
    '-C',
    checkout.seed,
    'push',
    '-q',
    'origin',
    'release-check/atc-gateway-images',
  ]);

  await checkout.git(['-C', checkout.seed, 'switch', '-q', 'main']);

  await Bun.write(
    `${checkout.seed}/images/atc-gateway/versions.env`,
    'GATEWAY_IMAGE_TAG=7.1.0\nBACKUP_IMAGE_TAG=3.1.0-r3\n',
  );

  await checkout.git(['-C', checkout.seed, 'commit', '-qam', 'cut backup revision r3']);
  await checkout.git(['-C', checkout.seed, 'push', '-q', 'origin', 'main']);
  await checkout.git(['-C', checkout.clone, 'pull', '-q', 'origin', 'main']);

  const rejected = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'rev-parse',
    'release-check/atc-gateway-images',
  ]);

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/atc-gateway:7.1.0': `sha256:${'1'.repeat(64)}`,
      'ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r3': `sha256:${'5'.repeat(64)}`,
    },
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      closedPRs: [{ headRefOid: rejected, isCrossRepository: false, number: 31 }],
    }),
    docker.handle,
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runPublishedImagesBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc-gateway-images'],
  );

  expect(status).toBe(0);
  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(stub.calls.map((call) => call.argv.join(' ')).at(-1)).toBe(
    'gh pr create --repo zgeoff/cloud --base main --head release-check/atc-gateway-images --title chore(atc-gateway-images): bump atc-gateway-images to 7.1.0+3.1.0-r3 --body-file - --label needs-review',
  );
});

test('it opens no pull request when main already pins the published digests', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': `${JSON.stringify(
      {
        'atc-gateway-image': { version: '7.1.0', digest: `sha256:${'1'.repeat(64)}` },
        'atc-gateway-backup-image': { tag: '3.1.0-r1', digest: `sha256:${'2'.repeat(64)}` },
      },
      null,
      2,
    )}\n`,
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.1.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/atc-gateway:7.1.0': `sha256:${'1'.repeat(64)}`,
      'ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1': `sha256:${'2'.repeat(64)}`,
    },
  });

  const stub = buildStubRunner(docker.handle, buildRealProgramHandler(['git'], checkout.env));

  const status = await runPublishedImagesBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc-gateway-images'],
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    [
      `atc-gateway-image already pins 7.1.0\natc-gateway-backup-image already pins 3.1.0-r1 sha256:${'2'.repeat(64)}\n`,
    ],
  ]);

  expect(stub.calls.filter((call) => call.argv[0] === 'gh')).toStrictEqual([]);
});

test('it fails before any branch when a tag is not on the registry', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.2.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  const docker = buildStubReleaseDocker({ manifests: {} });
  const stub = buildStubRunner(docker.handle, buildRealProgramHandler(['git'], checkout.env));

  const status = await runPublishedImagesBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc-gateway-images'],
  );

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['ERROR: ghcr.io/zgeoff/atc-gateway:7.2.0: not found\n'],
  ]);

  expect(stub.calls.map((call) => call.argv.slice(0, 2).join(' '))).toStrictEqual([
    'git fetch',
    'git show',
    'docker buildx',
  ]);
});

test('it leaves the branch to a newer push when main names other tags than the run published', async () => {
  const ctx = setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/atc-gateway/versions.env': 'GATEWAY_IMAGE_TAG=7.2.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
    'infra/Pulumi.prod.yaml': `    image: ghcr.io/zgeoff/atc-gateway:7.1.0@sha256:${'1'.repeat(64)}\n    backupImage: ghcr.io/zgeoff/atc-gateway-backup:3.1.0-r1@sha256:${'2'.repeat(64)}\n`,
  });

  await Bun.write(
    `${checkout.seed}/images/atc-gateway/versions.env`,
    'GATEWAY_IMAGE_TAG=7.3.0\nBACKUP_IMAGE_TAG=3.1.0-r1\n',
  );

  await checkout.git(['-C', checkout.seed, 'commit', '-qam', 'bump the gateway to 7.3.0']);
  await checkout.git(['-C', checkout.seed, 'push', '-q', 'origin', 'main']);

  const docker = buildStubReleaseDocker({ manifests: {} });
  const stub = buildStubRunner(docker.handle, buildRealProgramHandler(['git'], checkout.env));

  const status = await runPublishedImagesBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc-gateway-images'],
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    [
      "main names 7.3.0 3.1.0-r1, not the published 7.2.0 3.1.0-r1: the run for main's tags pins them\n",
    ],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(stub.calls.map((call) => call.argv.slice(0, 2).join(' '))).toStrictEqual([
    'git fetch',
    'git show',
  ]);
});

test('it refuses a dependency that is not a published-images record', async () => {
  const ctx = setupTest();
  const stub = buildStubRunner();

  const status = await runPublishedImagesBump(
    { cwd: '/nonexistent', env: {}, run: stub.run, ...ctx },
    ['atc'],
  );

  expect(status).toBe(2);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['usage: run-published-images-bump.ts <atc-gateway-images>\n'],
  ]);
});
