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
    },
    grants: [
      { src: ['autogroup:member'], dst: ['*'], ip: ['*'] },
      { src: ['tag:imp'], dst: ['tag:imp'], ip: ['tcp:7070'] },
      { src: ['tag:cloud'], dst: ['home-pc'], ip: ['tcp:8415'] },
      { src: ['tag:cloud'], dst: ['imp-geoffcloud'], ip: ['tcp:443'] },
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
