import { expect, mock, test } from 'bun:test';
import { server } from '../mocks/node.ts';
import { buildRealProgramHandler } from '../test-utils/build-real-program-handler.ts';
import { buildStubNPMRegistry } from '../test-utils/build-stub-npm-registry.ts';
import { buildStubReleaseDocker } from '../test-utils/build-stub-release-docker.ts';
import { buildStubReleaseGH } from '../test-utils/build-stub-release-gh.ts';
import { buildStubRunner } from '../test-utils/build-stub-runner.ts';
import { createCloudCheckout } from '../test-utils/create-cloud-checkout.ts';
import { createNPMTarball } from '../test-utils/create-npm-tarball.ts';
import { runReleaseBump } from './run-release-bump.ts';

async function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  // the image the flake lock runs in, as the checkout's own scripts/nix-image.sh pins it
  const pins = await Bun.file(new URL('../nix-image.sh', import.meta.url)).text();

  const nixImage = /^NIX_IMAGE='(?<image>[^']+)'$/mu.exec(pins)?.groups?.['image'] ?? '';

  return { printOut, printErr, nixImage };
}

test('it opens an atc bump that waits for review on a major release', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/agent/Dockerfile': `ARG ATC_VERSION=4.2.0\nARG ATC_SHA256=${'1'.repeat(64)}\n`,
    'nixos/packages/atc.nix': `let\n  version = "2.26.2";\n  sha256 = "${'2'.repeat(64)}";\nin\n`,
    'images/atc-gateway/versions.env': `ATC_RELEASE=@zgeoff/atc@2.27.0\nATC_ASSET=atc-gateway-linux-x64\nATC_ASSET_SHA256=${'3'.repeat(64)}\nGATEWAY_IMAGE_TAG=2.27.0\n`,
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/atc': [
          {
            tag: '@zgeoff/atc@5.0.0',
            assets: {
              SHA256SUMS: `${'4'.repeat(64)}  atc-linux-x64\n${'5'.repeat(64)}  atc-gateway-linux-x64\n`,
            },
          },
        ],
      },
    }),
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runReleaseBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['atc', '5.0.0', '4.2.0', '2.26.2', '2.27.0'],
  );

  const stat = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'diff',
    '--stat=200',
    'main',
    'release-check/atc',
  ]);

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['pinned atc-agent 5.0.0\npinned atc-daemon 5.0.0\npinned atc-gateway 5.0.0\n'],
    ['https://github.com/zgeoff/cloud/pull/200\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(stat).toBe(
    'images/agent/Dockerfile           |  4 ++--\n images/atc-gateway/versions.env   |  6 +++---\n nixos/packages/atc.nix            |  4 ++--\n scripts/release/release-pins.json | 16 +++++++++++++++-\n 4 files changed, 22 insertions(+), 8 deletions(-)',
  );

  expect(
    stub.calls
      .filter((call) => call.argv[0] !== 'git')
      .map((call) => [call.argv.join(' '), call.stdin]),
  ).toStrictEqual([
    ['gh release download @zgeoff/atc@5.0.0 -R zgeoff/atc -p SHA256SUMS -O -', ''],
    [
      'gh pr list --repo zgeoff/cloud --head release-check/atc --state open --json number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      '',
    ],
    [
      'gh label create update:major --repo zgeoff/cloud --force --color d73a4a --description a major release',
      '',
    ],
    [
      'gh label create needs-review --repo zgeoff/cloud --force --color d73a4a --description waits for a review before it merges',
      '',
    ],
    [
      'gh pr create --repo zgeoff/cloud --base main --head release-check/atc --title chore(atc): bump atc to 5.0.0 --body-file - --label update:major,needs-review',
      "Bumps atc to [5.0.0](https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%405.0.0). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the agent image (`images/agent/Dockerfile`) | 4.2.0 | 5.0.0 |\n| the host's atc daemon (`nixos/packages/atc.nix`) | 2.26.2 | 5.0.0 |\n| the atc-gateway images (`images/atc-gateway/versions.env`) | 2.27.0 | 5.0.0 |\n\nIt waits for a review, because:\n\n- it is a major release.\n\nAfter the merge: Rebuild the agent image (`docs/runbooks/agent-image.md`). The atc-gateway images workflow publishes the gateway images and opens the pull request that pins their digests, which the `Deploy prod` workflow applies once it merges (`docs/runbooks/prod-apply.md`). Then switch the host (`docs/runbooks/workflows.md`), which refuses while the deployed gateway runs another atc major than the daemon pin.\n",
    ],
  ]);
});

test('it opens an imp patch bump that merges on its own', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'6'.repeat(64)}\n`,
    'nixos/flake.nix': '    imp = {\n      url = "github:zgeoff/impz/4211437b";\n    };\n',
    'nixos/flake.lock':
      '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}\n',
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'7'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'6'.repeat(64)}";\n`,
  });

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/imp-host:1.0.1': `sha256:${'8'.repeat(64)}`,
      'ghcr.io/zgeoff/imp-base:1.0.1': `sha256:${'9'.repeat(64)}`,
    },
    lock: '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}\n',
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/impz': [{ tag: 'v1.0.1', commit: 'c5bea94080fdde9e21e9720295c1ca727302662e' }],
      },
    }),
    docker.handle,
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runReleaseBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['imp', '1.0.1', '1.0.0', '1.0.0'],
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['pinned imp-host 1.0.1\npinned imp-base 1.0.1\n'],
    ['https://github.com/zgeoff/cloud/pull/200\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(
    stub.calls
      .filter((call) => call.argv[0] !== 'git')
      .map((call) => [call.argv.join(' '), call.stdin]),
  ).toStrictEqual([
    ['gh api repos/zgeoff/impz/commits/v1.0.1 --jq .sha', ''],
    [
      'docker buildx imagetools inspect ghcr.io/zgeoff/imp-host:1.0.1 --format {{json .Manifest}}',
      '',
    ],
    [
      'docker buildx imagetools inspect ghcr.io/zgeoff/imp-base:1.0.1 --format {{json .Manifest}}',
      '',
    ],
    [
      `docker run --rm -v ${checkout.clone}/nixos:/src -w /src ${ctx.nixImage} sh -c nix --extra-experimental-features 'nix-command flakes' flake lock && chown ${process.getuid?.() ?? 0}:${process.getgid?.() ?? 0} flake.lock`,
      '',
    ],
    [
      'gh pr list --repo zgeoff/cloud --head release-check/imp --state open --json number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      '',
    ],
    [
      'gh label create update:patch --repo zgeoff/cloud --force --color 0e8a16 --description a patch release',
      '',
    ],
    [
      'gh label create auto-merge --repo zgeoff/cloud --force --color 0e8a16 --description merges on its own once its checks pass',
      '',
    ],
    [
      'gh pr create --repo zgeoff/cloud --base main --head release-check/imp --title chore(imp): bump imp to 1.0.1 --body-file - --label update:patch,auto-merge',
      "Bumps imp to [1.0.1](https://github.com/zgeoff/impz/releases/tag/v1.0.1). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| imp's NixOS module and the imp-host image (`nixos/`) | 1.0.0 | 1.0.1 |\n| the imp-base image (`images/agent/Dockerfile`) | 1.0.0 | 1.0.1 |\n\nIt merges on its own once every check on its head passes, including the NixOS checks when it changes `nixos/`.\n\nAfter the merge: Copy impd's database, then switch the host, as `docs/runbooks/workflows.md` (Upgrade imp) describes; rebuild the agent image for imp-base (`docs/runbooks/agent-image.md`).\n",
    ],
  ]);
});

test('it locks the imp commit with the github token by name, never in an argv', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/agent/Dockerfile': `FROM ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'6'.repeat(64)}\n`,
    'nixos/flake.nix': '    imp = {\n      url = "github:zgeoff/impz/4211437b";\n    };\n',
    'nixos/flake.lock':
      '{"nodes":{"imp":{"locked":{"rev":"4211437b337cc691e4e7a24785ec7cc21db6dfc3"}}}}\n',
    'nixos/hosts/geoffcloud/configuration.nix': `    image = "ghcr.io/zgeoff/imp-host:1.0.0@sha256:${'7'.repeat(64)}";\n    impRegistryImage = "ghcr.io/zgeoff/imp-base:1.0.0@sha256:${'6'.repeat(64)}";\n`,
  });

  const docker = buildStubReleaseDocker({
    manifests: {
      'ghcr.io/zgeoff/imp-host:1.0.1': `sha256:${'8'.repeat(64)}`,
      'ghcr.io/zgeoff/imp-base:1.0.1': `sha256:${'9'.repeat(64)}`,
    },
    lock: '{"nodes":{"imp":{"locked":{"rev":"c5bea94080fdde9e21e9720295c1ca727302662e"}}}}\n',
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/impz': [{ tag: 'v1.0.1', commit: 'c5bea94080fdde9e21e9720295c1ca727302662e' }],
      },
    }),
    docker.handle,
    buildRealProgramHandler(['git'], checkout.env),
  );

  await runReleaseBump(
    {
      cwd: checkout.clone,
      env: { ...checkout.env, NIX_GITHUB_TOKEN: 'ghs_exampletoken' },
      run: stub.run,
      ...ctx,
    },
    ['imp', '1.0.1', '1.0.0', '1.0.0'],
  );

  const flake = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'show',
    'release-check/imp:nixos/flake.nix',
  ]);

  expect(docker.nixConfigs).toStrictEqual(['access-tokens = github.com=ghs_exampletoken']);

  expect(stub.calls.flatMap((call) => call.argv)).not.toSatisfyAny((arg: string) =>
    arg.includes('ghs_exampletoken'),
  );

  expect(flake).toBe('imp = {\n      url = "github:zgeoff/impz/c5bea940";\n    };');
});

test('it flags a nixie bump with the migrations of a release between', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'infra/Pulumi.prod.yaml': `  geoff-cloud:nixie:\n    image: ghcr.io/zgeoff/nixie:0.7.0@sha256:${'a'.repeat(64)}\n    webImage: ghcr.io/zgeoff/nixie-web:0.7.0@sha256:${'b'.repeat(64)}\n`,
  });

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.7.2',
            notes: `## Migrations\n\nThis release adds no migration since v0.7.1.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie-fetch@sha256:${'c'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie@sha256:${'d'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'e'.repeat(64)}\`\n`,
          },
          {
            tag: 'v0.7.1',
            notes:
              '## Migrations\n\nThe migrations this release adds since v0.7.0, and whether v0.7.0 can read the schema each leaves.\n\n| Version | Migration | Readable by v0.7.0 |\n| ------- | --------- | ------------------ |\n| 10 | create the reminders table | yes |\n',
          },
          {
            tag: 'v0.7.0',
            notes: `## Migrations\n\nThis release adds no migration since v0.6.2.\n\n## Images\n\n- \`ghcr.io/zgeoff/nixie-fetch@sha256:${'c'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie@sha256:${'a'.repeat(64)}\`\n- \`ghcr.io/zgeoff/nixie-web@sha256:${'b'.repeat(64)}\`\n`,
          },
          { tag: 'v0.6.2' },
        ],
      },
    }),
    buildRealProgramHandler(['git'], checkout.env),
  );

  const status = await runReleaseBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['nixie', '0.7.2', '0.7.0', '0.7.0'],
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['pinned nixie 0.7.2\npinned nixie-web 0.7.2\n'],
    ['https://github.com/zgeoff/cloud/pull/200\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(
    stub.calls
      .filter((call) => call.argv[0] !== 'git')
      .map((call) => [call.argv.join(' '), call.stdin]),
  ).toStrictEqual([
    [
      'gh release list -R zgeoff/nixie --exclude-drafts --exclude-pre-releases --limit 30 --json tagName',
      '',
    ],
    ['gh release view v0.7.0 -R zgeoff/nixie --json body', ''],
    ['gh release view v0.7.2 -R zgeoff/nixie --json body', ''],
    ['gh release view v0.7.1 -R zgeoff/nixie --json body', ''],
    [
      'gh pr list --repo zgeoff/cloud --head release-check/nixie --state open --json number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      '',
    ],
    [
      'gh label create update:patch --repo zgeoff/cloud --force --color 0e8a16 --description a patch release',
      '',
    ],
    [
      'gh label create migrations --repo zgeoff/cloud --force --color d73a4a --description the release adds database migrations',
      '',
    ],
    [
      'gh label create needs-review --repo zgeoff/cloud --force --color d73a4a --description waits for a review before it merges',
      '',
    ],
    [
      'gh pr create --repo zgeoff/cloud --base main --head release-check/nixie --title chore(nixie): bump nixie to 0.7.2 --body-file - --label update:patch,migrations,needs-review',
      'Bumps nixie to [0.7.2](https://github.com/zgeoff/nixie/releases/tag/v0.7.2). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| nixie (`infra/Pulumi.prod.yaml`) | 0.7.0 | 0.7.2 |\n| nixie-web (`infra/Pulumi.prod.yaml`) | 0.7.0 | 0.7.2 |\n\nIt waits for a review, because:\n\n- a release in the bump adds database migrations, which a revert does not undo.\n\nAfter the merge: The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). Check the deploy (`docs/runbooks/nixie.md`).\n',
    ],
  ]);
});

test('it opens an auto mode patch bump that merges on its own', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=0.19.3\nARG AUTO_MODE_SHA256=${'d'.repeat(64)}\n`,
  });

  const tarball = await createNPMTarball({ name: 'auto-mode', version: '0.19.4' });

  server.use(...buildStubNPMRegistry({ 'auto-mode': { '0.19.4': { tarball } } }));

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git', 'tar'], checkout.env),
  );

  const status = await runReleaseBump(
    { cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx },
    ['auto-mode', '0.19.4', '0.19.3'],
  );

  expect(status).toBe(0);

  expect(ctx.printOut.mock.calls).toStrictEqual([
    ['pinned auto-mode 0.19.4\n'],
    ['https://github.com/zgeoff/cloud/pull/200\n'],
  ]);

  expect(ctx.printErr.mock.calls).toStrictEqual([]);

  expect(
    stub.calls
      .filter((call) => call.argv[0] !== 'git' && call.argv[0] !== 'tar')
      .map((call) => [call.argv.join(' '), call.stdin]),
  ).toStrictEqual([
    [
      'gh pr list --repo zgeoff/cloud --head release-check/auto-mode --state open --json number,url,autoMergeRequest,labels,headRefOid,isCrossRepository',
      '',
    ],
    [
      'gh label create update:patch --repo zgeoff/cloud --force --color 0e8a16 --description a patch release',
      '',
    ],
    [
      'gh label create auto-merge --repo zgeoff/cloud --force --color 0e8a16 --description merges on its own once its checks pass',
      '',
    ],
    [
      'gh pr create --repo zgeoff/cloud --base main --head release-check/auto-mode --title chore(auto-mode): bump auto-mode to 0.19.4 --body-file - --label update:patch,auto-merge',
      'Bumps auto-mode to [0.19.4](https://github.com/zgeoff/auto-mode/releases/tag/auto-mode-v0.19.4). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the agent image (`images/agent/Dockerfile`) | 0.19.3 | 0.19.4 |\n\nIt merges on its own once every check on its head passes, including the NixOS checks when it changes `nixos/`.\n\nAfter the merge: Rebuild the agent image (`docs/runbooks/agent-image.md`). Gateway sessions load the new mod from `/opt/auto-mode/mods/auto-mode` once they start on the new image.\n',
    ],
  ]);
});

test('it pins the auto mode tarball sum that the registry serves', async () => {
  const ctx = await setupTest();

  const checkout = await createCloudCheckout({
    'scripts/release/release-pins.json': '{}\n',
    'images/agent/Dockerfile': `ARG AUTO_MODE_VERSION=0.19.3\nARG AUTO_MODE_SHA256=${'d'.repeat(64)}\n`,
  });

  const tarball = await createNPMTarball({ name: 'auto-mode', version: '0.19.4' });

  server.use(...buildStubNPMRegistry({ 'auto-mode': { '0.19.4': { tarball } } }));

  const stub = buildStubRunner(
    buildStubReleaseGH({}),
    buildRealProgramHandler(['git', 'tar'], checkout.env),
  );

  await runReleaseBump({ cwd: checkout.clone, env: checkout.env, run: stub.run, ...ctx }, [
    'auto-mode',
    '0.19.4',
    '0.19.3',
  ]);

  const dockerfile = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'show',
    'release-check/auto-mode:images/agent/Dockerfile',
  ]);

  expect(dockerfile).toBe(
    `ARG AUTO_MODE_VERSION=0.19.4\nARG AUTO_MODE_SHA256=${new Bun.CryptoHasher('sha256').update(tarball).digest('hex')}`,
  );
});

test('it fails without a pull request when npm lacks the auto mode release', async () => {
  const ctx = await setupTest();

  server.use(...buildStubNPMRegistry({}));

  const stub = buildStubRunner(buildStubReleaseGH({}));

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['auto-mode', '0.19.4', '0.19.3'],
  );

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['the npm registry answered 404 for https://registry.npmjs.org/auto-mode/0.19.4\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it refuses an auto mode tarball away from where the image fetches it', async () => {
  const ctx = await setupTest();

  server.use(
    ...buildStubNPMRegistry({
      'auto-mode': {
        '0.19.4': {
          tarball: new TextEncoder().encode('not fetched'),
          tarballURL: 'https://registry.example.invalid/auto-mode-0.19.4.tgz',
        },
      },
    }),
  );

  const stub = buildStubRunner(buildStubReleaseGH({}));

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['auto-mode', '0.19.4', '0.19.3'],
  );

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      "npm lists auto-mode 0.19.4's tarball at https://registry.example.invalid/auto-mode-0.19.4.tgz, not where the agent image fetches it\n",
    ],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it fails without a pull request when the release lacks its sums', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubReleaseGH({ releases: { 'zgeoff/atc': [{ tag: '@zgeoff/atc@5.0.0' }] } }),
  );

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['atc', '5.0.0', '4.2.0', '2.26.2', '2.27.0'],
  );

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);
  expect(ctx.printErr.mock.calls).toStrictEqual([['release not found\n']]);

  expect(stub.calls.map((call) => call.argv.join(' '))).toStrictEqual([
    'gh release download @zgeoff/atc@5.0.0 -R zgeoff/atc -p SHA256SUMS -O -',
  ]);
});

test('it refuses a dependency it does not know', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['atc-gateway', '5.0.0', '4.2.0'],
  );

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ["not a release check dependency: 'atc-gateway'\n"],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it refuses a pinned version count that does not match the pins', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['atc', '5.0.0', '4.2.0'],
  );

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['atc has 3 pins, but 1 pinned versions were given\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it refuses a bump line without a pinned version', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['atc', '5.0.0'],
  );

  expect(status).toBe(2);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    ['atc has 3 pins, but 0 pinned versions were given\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});

test('it fails without a pull request when the release list misses the pinned release', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner(
    buildStubReleaseGH({
      releases: {
        'zgeoff/nixie': [
          {
            tag: 'v0.7.2',
            notes: '## Migrations\n\nThis release adds no migration since v0.7.1.\n',
          },
          { tag: 'v0.7.1' },
        ],
      },
    }),
  );

  const status = await runReleaseBump(
    { cwd: '/nonexistent/clone', env: {}, run: stub.run, ...ctx },
    ['nixie', '0.7.2', '0.5.0', '0.5.0'],
  );

  expect(status).toBe(1);
  expect(ctx.printOut.mock.calls).toStrictEqual([]);

  expect(ctx.printErr.mock.calls).toStrictEqual([
    [
      'the latest 30 nixie releases do not reach the pinned v0.5.0, so the releases between go unread\n',
    ],
  ]);

  expect(stub.calls.map((call) => call.argv.join(' '))).toStrictEqual([
    'gh release list -R zgeoff/nixie --exclude-drafts --exclude-pre-releases --limit 30 --json tagName',
  ]);
});
