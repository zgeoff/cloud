import { expect, test } from 'bun:test';
import { output } from '@pulumi/pulumi';
import { buildOwnerPolicyArgs } from './build-owner-policy-args.ts';

test("it allows only the owner's address, signed in with the one-time PIN", () => {
  const identityProviderID = output('one-time-pin-id');
  const ownerEmail = output('owner@example.test');

  expect(
    buildOwnerPolicyArgs({ accountID: 'account-id', identityProviderID, ownerEmail }),
  ).toStrictEqual({
    accountId: 'account-id',
    name: 'atc gateway owner',
    decision: 'allow',
    includes: [{ email: { email: ownerEmail } }],
    requires: [{ loginMethod: { id: identityProviderID } }],
  });
});
