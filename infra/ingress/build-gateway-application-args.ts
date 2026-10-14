import type { ZeroTrustAccessApplicationArgs } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { atcGatewayPaths } from './atc-gateway-paths.ts';

interface GatewayApplicationInputs {
  readonly accountID: string;

  // the gateway's public hostname, the one the tunnel routes
  readonly hostname: string;

  // the one-time PIN identity provider's ID
  readonly identityProviderID: Output<string>;

  // the owner policy's ID
  readonly policyID: Output<string>;
}

// The Access application in front of the atc gateway's browser paths only, so the machine paths
// carry no Access challenge or cookie. It offers the one-time PIN alone and applies the owner policy
// alone; passing it grants nothing in atc, which still runs its own sign-in, consent and token checks.
export function buildGatewayApplicationArgs(
  inputs: GatewayApplicationInputs,
): ZeroTrustAccessApplicationArgs {
  return {
    accountId: inputs.accountID,
    name: 'atc gateway sign-in',
    type: 'self_hosted',
    domain: `${inputs.hostname}${atcGatewayPaths.browser[0]}`,
    destinations: atcGatewayPaths.browser.map((path) => ({
      type: 'public',
      uri: `${inputs.hostname}${path}`,
    })),
    policies: [{ id: inputs.policyID, precedence: 1 }],
    allowedIdps: [inputs.identityProviderID],
    autoRedirectToIdentity: true,
    appLauncherVisible: false,
    sessionDuration: '1h',
    httpOnlyCookieAttribute: true,
    sameSiteCookieAttribute: 'lax',
  };
}
