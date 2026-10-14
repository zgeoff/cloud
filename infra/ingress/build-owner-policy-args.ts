import type { ZeroTrustAccessPolicyArgs } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';

interface OwnerPolicyInputs {
  readonly accountID: string;

  // the one-time PIN identity provider's ID
  readonly identityProviderID: Output<string>;

  // the owner's address, where Access sends the one-time PIN, from the secret stack config
  readonly ownerEmail: Output<string>;
}

// The Access policy that lets the owner through: the owner's address, signed in with a one-time PIN.
// Access denies every identity that no allow policy matches, so this is the deny for everyone else.
export function buildOwnerPolicyArgs(inputs: OwnerPolicyInputs): ZeroTrustAccessPolicyArgs {
  return {
    accountId: inputs.accountID,
    name: 'atc gateway owner',
    decision: 'allow',
    includes: [{ email: { email: inputs.ownerEmail } }],
    requires: [{ loginMethod: { id: inputs.identityProviderID } }],
  };
}
