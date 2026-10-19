import type { ZeroTrustAccessPolicyArgs } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';

interface OwnerPolicyInputs {
  readonly accountID: string;

  readonly identityProviderID: Output<string>;

  readonly ownerEmail: Output<string>;
}

export function buildOwnerPolicyArgs(inputs: OwnerPolicyInputs): ZeroTrustAccessPolicyArgs {
  return {
    accountId: inputs.accountID,
    name: 'atc gateway owner',

    // Access denies every identity that no allow policy matches, so this is the deny for everyone
    // else
    decision: 'allow',
    includes: [{ email: { email: inputs.ownerEmail } }],
    requires: [{ loginMethod: { id: inputs.identityProviderID } }],
  };
}
