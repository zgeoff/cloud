import {
  ZeroTrustAccessApplication,
  ZeroTrustAccessPolicy,
  getZeroTrustOrganizationOutput,
} from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { buildOwnerPolicyArgs } from './build-owner-policy-args.ts';
import { buildSignInApplicationArgs } from './build-sign-in-application-args.ts';
import type { OriginAccess } from './build-tunnel-ingresses.ts';
import { parseTeamName } from './parse-team-name.ts';

interface OwnerAccessInputs {
  readonly accountID: string;

  // the start of each resource's name, such as `atc-gateway`
  readonly resourceName: string;

  // the start of each resource's display name, such as `atc gateway`
  readonly displayName: string;

  readonly hostname: string;
  readonly browserPaths: readonly [string, ...string[]];

  // the account's one-time PIN login
  readonly identityProviderID: Output<string>;

  readonly ownerEmail: Output<string>;
}

// an owner-only Access application on an origin's browser paths, and what cloudflared needs to
// check its token
export function createOwnerAccess(inputs: OwnerAccessInputs): OriginAccess {
  const policy = new ZeroTrustAccessPolicy(
    `${inputs.resourceName}-owner`,
    buildOwnerPolicyArgs({
      accountID: inputs.accountID,
      name: `${inputs.displayName} owner`,
      identityProviderID: inputs.identityProviderID,
      ownerEmail: inputs.ownerEmail,
    }),
  );

  const application = new ZeroTrustAccessApplication(
    `${inputs.resourceName}-sign-in`,
    buildSignInApplicationArgs({
      accountID: inputs.accountID,
      name: `${inputs.displayName} sign-in`,
      hostname: inputs.hostname,
      browserPaths: inputs.browserPaths,
      identityProviderID: inputs.identityProviderID,
      policyID: policy.id,
    }),
  );

  const organization = getZeroTrustOrganizationOutput({ accountId: inputs.accountID });

  return {
    teamName: organization.authDomain.apply(parseTeamName),
    audience: application.aud,
  };
}
