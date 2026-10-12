import type { Provider } from '@pulumi/kubernetes';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { all, secret } from '@pulumi/pulumi';
import { PrivateKey } from '@pulumi/tls';
import { Provider as ACMEProvider, Certificate, Registration } from '@pulumiverse/acme';

export interface NixieCertificateInputs {
  readonly namespace: Output<string>;
  readonly hostname: string;

  // Pulumi's own Cloudflare token, for the DNS-01 challenge
  readonly dnsToken: Output<string>;
}

// Let's Encrypt's certificate for nixie's host name, issued in the Pulumi run through a DNS-01
// challenge, so no DNS token enters the cluster. Returns the TLS Secret's name. An apply within 30
// days of expiry renews it, so with 90-day certificates an apply is due every 60 days.
export function createNixieCertificate(
  cluster: Provider,
  inputs: NixieCertificateInputs,
): Output<string> {
  const acme = new ACMEProvider('letsencrypt', {
    serverUrl: 'https://acme-v02.api.letsencrypt.org/directory',
  });

  const accountKey = new PrivateKey('nixie-acme-account', {
    algorithm: 'ECDSA',
    ecdsaCurve: 'P256',
  });

  const registration = new Registration(
    'nixie-acme',
    { accountKeyPem: accountKey.privateKeyPem },
    { provider: acme },
  );

  const certificate = new Certificate(
    'nixie',
    {
      accountKeyPem: registration.accountKeyPem,
      commonName: inputs.hostname,
      keyType: 'EC256',
      minDaysRemaining: 30,
      dnsChallenges: [
        { provider: 'cloudflare', config: { CF_DNS_API_TOKEN: secret(inputs.dnsToken) } },
      ],
    },
    { provider: acme },
  );

  return createTLSSecret(cluster, inputs.namespace, certificate);
}

// no fixed name: a renewal replaces the Secret, and the Ingress follows the new name
function createTLSSecret(
  cluster: Provider,
  namespace: Output<string>,
  certificate: Certificate,
): Output<string> {
  const tls = new Secret(
    'nixie-tls',
    {
      metadata: { namespace },
      type: 'kubernetes.io/tls',
      stringData: {
        'tls.crt': all([certificate.certificatePem, certificate.issuerPem]).apply(
          ([leaf, issuer]) => `${leaf.trimEnd()}\n${issuer}`,
        ),
        'tls.key': secret(certificate.privateKeyPem),
      },
    },
    { provider: cluster },
  );

  return tls.metadata.name;
}
