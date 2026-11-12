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

  // the prefix of the policy's and the application's resource names, such as `atc-gateway`
  readonly resourceName: string;

  // the prefix of their names in Cloudflare, such as `atc gateway`
  readonly name: string;

  readonly hostname: string;
  readonly browserPaths: readonly [string, ...string[]];
  readonly ownerEmail: Output<string>;

  // the account's one-time PIN login, which every owner-only application shares
  readonly identityProviderID: Output<string>;
}

// an owner-only Access application in front of a workload's sign-in pages
export function createOwnerAccess(inputs: OwnerAccessInputs): OriginAccess {
  const policy = new ZeroTrustAccessPolicy(
    `${inputs.resourceName}-owner`,
    buildOwnerPolicyArgs({
      accountID: inputs.accountID,
      name: `${inputs.name} owner`,
      identityProviderID: inputs.identityProviderID,
      ownerEmail: inputs.ownerEmail,
    }),
  );

  const application = new ZeroTrustAccessApplication(
    `${inputs.resourceName}-sign-in`,
    buildSignInApplicationArgs({
      accountID: inputs.accountID,
      name: `${inputs.name} sign-in`,
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
