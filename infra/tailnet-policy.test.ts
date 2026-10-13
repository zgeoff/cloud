import { expect, test } from 'bun:test';
import { tailnetPolicy } from './tailnet-policy.ts';
import { buildStubTailnetFilter } from './test-utils/build-stub-tailnet-filter.ts';

// Acl replaces the whole tailnet file, so the whole policy is the contract: a lost
// grant, SSH rule or tag owner fails here before it reaches the tailnet
test('it holds every host, tag owner, grant, SSH rule and node attribute the tailnet relies on', () => {
  expect(tailnetPolicy).toStrictEqual({
    hosts: {
      'home-pc': '100.67.122.120',
      'imp-geoffcloud': '100.75.9.119',
      geoffcloud: '100.69.47.33',
    },
    tagOwners: {
      'tag:cloud': ['autogroup:admin', 'tag:cloud'],
      'tag:imp': ['autogroup:admin', 'tag:imp'],
      'tag:imp-e2e': ['autogroup:admin', 'tag:imp-e2e'],
      'tag:cloud-deploy': ['autogroup:admin', 'tag:cloud-deploy'],
    },
    grants: [
      {
        src: ['autogroup:member'],
        dst: ['*'],
        ip: ['tcp:1-6442', 'tcp:6444-65535', 'udp:*', 'icmp:*', '58:*'],
      },
      { src: ['tag:imp'], dst: ['tag:imp'], ip: ['tcp:7070'] },
      { src: ['tag:cloud'], dst: ['home-pc'], ip: ['tcp:8415'] },
      { src: ['tag:cloud'], dst: ['imp-geoffcloud'], ip: ['tcp:443'] },
      { src: ['tag:imp-e2e'], dst: ['tag:imp-e2e'], ip: ['tcp:7070'] },
      { src: ['autogroup:member'], dst: ['geoffcloud'], ip: ['tcp:443'] },
      { src: ['tag:cloud'], dst: ['imp-geoffcloud'], ip: ['tcp:443'] },
      { src: ['tag:cloud-deploy'], dst: ['geoffcloud'], ip: ['tcp:6443'] },
      {
        src: ['autogroup:member'],
        dst: ['autogroup:member', 'tag:imp', 'tag:imp-e2e', 'tag:cloud-deploy'],
        ip: ['tcp:6443'],
      },
      { src: ['home-pc'], dst: ['geoffcloud'], ip: ['tcp:6443'] },
    ],
    ssh: [
      {
        action: 'check',
        src: ['autogroup:member'],
        dst: ['autogroup:self'],
        users: ['autogroup:nonroot', 'root'],
      },
      {
        action: 'accept',
        src: ['autogroup:admin'],
        dst: ['tag:cloud'],
        users: ['autogroup:nonroot', 'root'],
      },
    ],
    nodeAttrs: [{ target: ['autogroup:member'], attr: ['funnel'] }],
  });
});

// imp's e2e nodes are throwaway: a grant that took them anywhere but each other
// would let a test run reach a live impd
test('it lets tag:imp-e2e reach only other tag:imp-e2e nodes, on the API port only', () => {
  const fromE2E = tailnetPolicy.grants.filter((grant) => grant.src.includes('tag:imp-e2e'));

  expect(fromE2E).toStrictEqual([{ src: ['tag:imp-e2e'], dst: ['tag:imp-e2e'], ip: ['tcp:7070'] }]);
  expect(tailnetPolicy.tagOwners['tag:imp-e2e']).toStrictEqual(['autogroup:admin', 'tag:imp-e2e']);
});

// the prod apply job's runner holds full-account cloud credentials, so its node reaches the k3s
// API and nothing else on the tailnet, and no SSH rule names it
test('it lets tag:cloud-deploy reach only the k3s API on geoffcloud', () => {
  const fromDeploy = tailnetPolicy.grants.filter((grant) => grant.src.includes('tag:cloud-deploy'));
  const sshToDeploy = tailnetPolicy.ssh.filter((rule) => rule.dst.includes('tag:cloud-deploy'));

  expect(fromDeploy).toStrictEqual([
    { src: ['tag:cloud-deploy'], dst: ['geoffcloud'], ip: ['tcp:6443'] },
  ]);

  expect(sshToDeploy).toStrictEqual([]);
});

// a k3s credential copied off the host (a snapshot, a leaked kubeconfig) must not work from an
// ordinary member device, the owner's own devices included
test('it refuses the k3s API on geoffcloud to an admin device that is not home-pc', () => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  expect(
    filter.canConnect(
      { ip: '100.64.0.10', roles: ['admin', 'member'], tags: [] },
      { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port: 6443 },
    ),
  ).toBe(false);
});

test('it refuses the k3s API on geoffcloud to a member device', () => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  expect(
    filter.canConnect(
      { ip: '100.64.0.11', roles: ['member'], tags: [] },
      { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port: 6443 },
    ),
  ).toBe(false);
});

test.each(['tag:cloud', 'tag:imp', 'tag:imp-e2e'])(
  'it refuses the k3s API on geoffcloud to a %s node',
  (tag) => {
    const filter = buildStubTailnetFilter(tailnetPolicy);

    expect(
      filter.canConnect(
        { ip: '100.64.0.12', roles: [], tags: [tag] },
        { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
        { proto: 'tcp', port: 6443 },
      ),
    ).toBe(false);
  },
);

// the operator's Pulumi runs: preview, up and drift
test('it lets home-pc reach the k3s API on geoffcloud', () => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  expect(
    filter.canConnect(
      { ip: '100.67.122.120', roles: ['admin', 'member'], tags: [] },
      { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port: 6443 },
    ),
  ).toBe(true);
});

// the prod apply job's runner: its wait for the API (/livez) and Pulumi's apply
test('it lets a tag:cloud-deploy runner reach the k3s API on geoffcloud', () => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  expect(
    filter.canConnect(
      { ip: '100.64.0.13', roles: [], tags: ['tag:cloud-deploy'] },
      { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port: 6443 },
    ),
  ).toBe(true);
});

// the change closes geoffcloud's TCP 6443 to members and nothing else they reached
test('it keeps a member device on every other TCP port of geoffcloud', () => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  const otherPorts = Array.from({ length: 65_535 }, (_, index) => index + 1).filter(
    (port) => port !== 6443,
  );

  expect(otherPorts).toSatisfyAll((port: number) =>
    filter.canConnect(
      { ip: '100.64.0.11', roles: ['member'], tags: [] },
      { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
      { proto: 'tcp', port },
    ),
  );
});

test.each([
  ['udp', 6443],
  ['udp', 41_641],
  ['icmp', 0],
  ['ipv6-icmp', 0],
] as const)('it keeps a member device on %s port %d of geoffcloud', (proto, port) => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  expect(
    filter.canConnect(
      { ip: '100.64.0.11', roles: ['member'], tags: [] },
      { ip: '100.69.47.33', roles: [], tags: ['tag:cloud'] },
      { proto, port },
    ),
  ).toBe(true);
});

test.each([
  ['another member device', { ip: '100.64.0.14', roles: ['member'], tags: [] }],
  ['imp-geoffcloud', { ip: '100.75.9.119', roles: [], tags: ['tag:imp'] }],
  ['a tag:imp-e2e node', { ip: '100.64.0.15', roles: [], tags: ['tag:imp-e2e'] }],
  ['a tag:cloud-deploy runner', { ip: '100.64.0.13', roles: [], tags: ['tag:cloud-deploy'] }],
] as const)('it keeps a member device on TCP 6443 of %s', (_, destination) => {
  const filter = buildStubTailnetFilter(tailnetPolicy);

  expect(
    filter.canConnect({ ip: '100.64.0.11', roles: ['member'], tags: [] }, destination, {
      proto: 'tcp',
      port: 6443,
    }),
  ).toBe(true);
});
