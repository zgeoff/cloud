import type { ZeroTrustAccessApplicationArgs } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';
import { atcGatewayPaths } from './atc-gateway-paths.ts';

interface GatewayApplicationInputs {
  readonly accountID: string;

  readonly hostname: string;

  readonly identityProviderID: Output<string>;

  readonly policyID: Output<string>;
}

export function buildGatewayApplicationArgs(
  inputs: GatewayApplicationInputs,
): ZeroTrustAccessApplicationArgs {
  return {
    accountId: inputs.accountID,
    name: 'atc gateway sign-in',
    type: 'self_hosted',
    domain: `${inputs.hostname}${atcGatewayPaths.browser[0]}`,

    // browser paths only, so the machine paths carry no Access challenge or cookie
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
