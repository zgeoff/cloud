import { expect, test } from 'bun:test';
import { tailnetPolicy } from './tailnet-policy.ts';

// Acl replaces the whole tailnet file, so the whole policy is the contract: a lost
// grant, SSH rule or tag owner fails here before it reaches the tailnet
test('it holds every host, tag owner, grant, SSH rule and node attribute the tailnet relies on', () => {
  expect(tailnetPolicy).toStrictEqual({
    hosts: {
      'home-pc': '100.67.122.120',
      'imp-geoffcloud': '100.75.9.119',
    },
    tagOwners: {
      'tag:cloud': ['autogroup:admin', 'tag:cloud'],
      'tag:imp': ['autogroup:admin', 'tag:imp'],
      'tag:imp-e2e': ['autogroup:admin', 'tag:imp-e2e'],
    },
    grants: [
      { src: ['autogroup:member'], dst: ['*'], ip: ['*'] },
      { src: ['tag:imp'], dst: ['tag:imp'], ip: ['tcp:7070'] },
      { src: ['tag:cloud'], dst: ['home-pc'], ip: ['tcp:8415'] },
      { src: ['tag:cloud'], dst: ['imp-geoffcloud'], ip: ['tcp:443'] },
      { src: ['tag:imp-e2e'], dst: ['tag:imp-e2e'], ip: ['tcp:7070'] },
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
