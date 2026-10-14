import {
  ZeroTrustAccessApplication,
  ZeroTrustAccessIdentityProvider,
  ZeroTrustAccessPolicy,
  getZeroTrustOrganizationOutput,
} from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { buildGatewayApplicationArgs } from './build-gateway-application-args.ts';
import { buildOwnerPolicyArgs } from './build-owner-policy-args.ts';
import type { OriginAccess } from './build-tunnel-ingresses.ts';
import { parseTeamName } from './parse-team-name.ts';

interface GatewayAccessInputs {
  readonly accountID: string;
  readonly hostname: string;
  readonly ownerEmail: Output<string>;
}

// The owner-only Access application in front of the atc gateway's sign-in pages, and what
// cloudflared needs to check its tokens. atc keeps its grants and tokens in its own database, so
// creating, changing or removing this policy leaves every one of them valid.
export function createGatewayAccess(inputs: GatewayAccessInputs): OriginAccess {
  // the account's one-time PIN login, which needs no outside identity provider
  const identityProvider = new ZeroTrustAccessIdentityProvider('one-time-pin', {
    accountId: inputs.accountID,
    name: 'One-time PIN',
    type: 'onetimepin',
    config: {},
  });

  const policy = new ZeroTrustAccessPolicy(
    'atc-gateway-owner',
    buildOwnerPolicyArgs({
      accountID: inputs.accountID,
      identityProviderID: identityProvider.id,
      ownerEmail: inputs.ownerEmail,
    }),
  );

  const application = new ZeroTrustAccessApplication(
    'atc-gateway-sign-in',
    buildGatewayApplicationArgs({
      accountID: inputs.accountID,
      hostname: inputs.hostname,
      identityProviderID: identityProvider.id,
      policyID: policy.id,
    }),
  );

  const organization = getZeroTrustOrganizationOutput({ accountId: inputs.accountID });

  return {
    teamName: organization.authDomain.apply(parseTeamName),
    audience: application.aud,
  };
}
