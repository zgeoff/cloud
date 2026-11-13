import type { Output } from '@pulumi/pulumi';
import { PrivateKey } from '@pulumi/tls';
import { Provider as ACMEProvider, Registration } from '@pulumiverse/acme';

// the Let's Encrypt account of every name that nixie's Traefik serves
export interface NixieACMEAccount {
  readonly provider: ACMEProvider;
  readonly accountKeyPem: Output<string>;
}

export function createNixieACMEAccount(): NixieACMEAccount {
  const provider = new ACMEProvider('letsencrypt', {
    serverUrl: 'https://acme-v02.api.letsencrypt.org/directory',
  });

  const accountKey = new PrivateKey('nixie-acme-account', {
    algorithm: 'ECDSA',
    ecdsaCurve: 'P256',
  });

  const registration = new Registration(
    'nixie-acme',
    { accountKeyPem: accountKey.privateKeyPem },
    { provider },
  );

  return { provider, accountKeyPem: registration.accountKeyPem };
}
