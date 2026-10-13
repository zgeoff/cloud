import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkTopology } from './check-topology.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'check-topology-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  // the directories of the three files it reads, which every checkout has
  await mkdir(join(root, 'infra'));
  await mkdir(join(root, 'deploy', 'nixie'), { recursive: true });
  await mkdir(join(root, '.github', 'workflows'), { recursive: true });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { root, printOut, printErr };
}

test('it passes when every copy agrees with the constants', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    image: ghcr.io/zgeoff/atc-gateway:2.27.0
    daemons:
      geoffcloud: { address: 100.69.47.33:8415, daemonID: 087031fd-6df6-42fb-a2e9-76e1f0e363d9 }
      home-pc: { address: 100.67.122.120:8415 }
`,
  );

  await writeFile(
    join(ctx.root, 'deploy', 'nixie', 'config.yaml'),
    `imp:
  url: https://imps.geoff.cloud
  host_addresses: [104.250.100.18/24, 2401:a4a0:4:17f::1/64, 172.17.0.1/16, 100.69.47.33/32, 10.42.0.1/24]
  egress_deny: [10.42.0.0/16, 10.43.0.0/16]
`,
  );

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  build: { steps: [{ uses: actions/checkout@v6 }] }
  apply: { steps: [{ uses: tailscale/github-action@d1b6cd2, with: { tags: tag:cloud-deploy } }] }
`,
  );

  const exitCode = await checkTopology({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'check-topology: 9 copies agree with packages/topology\n',
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it fails a stack config daemon address that differs from the constants', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    daemons:
      geoffcloud: { address: 100.69.47.33:8415 }
      home-pc: { address: 100.67.122.121:8415 }
`,
  );

  await writeFile(
    join(ctx.root, 'deploy', 'nixie', 'config.yaml'),
    `imp:
  url: https://imps.geoff.cloud
  host_addresses: [104.250.100.18/24, 2401:a4a0:4:17f::1/64, 172.17.0.1/16, 100.69.47.33/32]
  egress_deny: [10.42.0.0/16, 10.43.0.0/16]
`,
  );

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply: { steps: [{ uses: tailscale/github-action@d1b6cd2, with: { tags: tag:cloud-deploy } }] }
`,
  );

  const exitCode = await checkTopology({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-topology: infra/Pulumi.prod.yaml: geoff-cloud:atcGateway.daemons.home-pc.address is "100.67.122.121:8415", but packages/topology gives "100.67.122.120:8415"\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test("it fails nixie's config when its host addresses and egress ranges differ from the constants", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    daemons:
      geoffcloud: { address: 100.69.47.33:8415 }
      home-pc: { address: 100.67.122.120:8415 }
`,
  );

  await writeFile(
    join(ctx.root, 'deploy', 'nixie', 'config.yaml'),
    `imp:
  url: https://imps.geoff.cloud
  host_addresses: [104.250.100.19/24, 2401:a4a0:4:17f::1/64, 172.17.0.1/16]
  egress_deny: [10.42.0.0/16]
`,
  );

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply: { steps: [{ uses: tailscale/github-action@d1b6cd2, with: { tags: tag:cloud-deploy } }] }
`,
  );

  const exitCode = await checkTopology({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-topology: deploy/nixie/config.yaml: imp.host_addresses[0] is "104.250.100.19", but packages/topology gives "104.250.100.18"\n' +
      'check-topology: deploy/nixie/config.yaml: imp.host_addresses[3] is nothing, but packages/topology gives "100.69.47.33"\n' +
      'check-topology: deploy/nixie/config.yaml: imp.egress_deny is ["10.42.0.0/16"], but packages/topology gives ["10.42.0.0/16","10.43.0.0/16"]\n',
  );
});

test("it fails the deploy workflow's tailnet tag when it differs from the constants", async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    daemons:
      geoffcloud: { address: 100.69.47.33:8415 }
      home-pc: { address: 100.67.122.120:8415 }
`,
  );

  await writeFile(
    join(ctx.root, 'deploy', 'nixie', 'config.yaml'),
    `imp:
  url: https://imps.geoff.cloud
  host_addresses: [104.250.100.18/24, 2401:a4a0:4:17f::1/64, 172.17.0.1/16, 100.69.47.33/32]
  egress_deny: [10.42.0.0/16, 10.43.0.0/16]
`,
  );

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply: { steps: [{ uses: tailscale/github-action@d1b6cd2, with: { tags: tag:cloud } }] }
`,
  );

  const exitCode = await checkTopology({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-topology: .github/workflows/deploy-prod.yml: jobs.apply: tailscale/github-action\'s tags is "tag:cloud", but packages/topology gives "tag:cloud-deploy"\n',
  );
});

test('it fails a file it cannot read before it compares any copy', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    daemons:
      geoffcloud: { address: 100.69.47.33:8416 }
      home-pc: { address: 100.67.122.120:8415 }
`,
  );

  await writeFile(
    join(ctx.root, '.github', 'workflows', 'deploy-prod.yml'),
    `jobs:
  apply: { steps: [{ uses: tailscale/github-action@d1b6cd2, with: { tags: tag:cloud-deploy } }] }
`,
  );

  const exitCode = await checkTopology({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-topology: cannot read deploy/nixie/config.yaml\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it fails a copy that its file lacks', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'infra', 'Pulumi.prod.yaml'),
    `config:
  geoff-cloud:atcGateway:
    daemons:
      geoffcloud: { address: 100.69.47.33:8415 }
`,
  );

  await writeFile(
    join(ctx.root, 'deploy', 'nixie', 'config.yaml'),
    `imp:
  url: https://imps.geoff.cloud
  host_addresses: [104.250.100.18/24, 2401:a4a0:4:17f::1/64, 172.17.0.1/16, 100.69.47.33/32]
  egress_deny: [10.42.0.0/16, 10.43.0.0/16]
`,
  );

  await writeFile(join(ctx.root, '.github', 'workflows', 'deploy-prod.yml'), 'jobs: {}\n');

  const exitCode = await checkTopology({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'check-topology: infra/Pulumi.prod.yaml: geoff-cloud:atcGateway.daemons.home-pc.address is nothing, but packages/topology gives "100.67.122.120:8415"\n',
  );
});

test('it prints its usage for more than one argument', async () => {
  const ctx = await setupTest();

  const exitCode = await checkTopology({
    args: [ctx.root, ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith('usage: check-topology.ts [repo root]\n');
});
