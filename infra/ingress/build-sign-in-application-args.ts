import type { ZeroTrustAccessApplicationArgs } from '@pulumi/cloudflare';
import type { Output } from '@pulumi/pulumi';

interface SignInApplicationInputs {
  readonly accountID: string;

  // the application's name in Cloudflare
  readonly name: string;

  readonly hostname: string;

  // the pages the owner's browser loads to sign in; the first is the application's domain
  readonly browserPaths: readonly [string, ...string[]];

  readonly identityProviderID: Output<string>;

  readonly policyID: Output<string>;
}

export function buildSignInApplicationArgs(
  inputs: SignInApplicationInputs,
): ZeroTrustAccessApplicationArgs {
  return {
    accountId: inputs.accountID,
    name: inputs.name,
    type: 'self_hosted',
    domain: `${inputs.hostname}${inputs.browserPaths[0]}`,

    // browser paths only, so the machine paths carry no Access challenge or cookie
    destinations: inputs.browserPaths.map((path) => ({
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
