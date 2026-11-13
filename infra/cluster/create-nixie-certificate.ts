import type { Provider } from '@pulumi/kubernetes';
import { Secret } from '@pulumi/kubernetes/core/v1';
import type { Output } from '@pulumi/pulumi';
import { all, secret } from '@pulumi/pulumi';
import { Certificate } from '@pulumiverse/acme';
import type { NixieACMEAccount } from './create-nixie-acme-account.ts';

export interface NixieCertificateInputs {
  // the certificate's resource name, and with "-tls" its Secret's
  readonly name: string;
  readonly account: NixieACMEAccount;
  readonly namespace: Output<string>;
  readonly hostname: string;
  readonly dnsToken: Output<string>;
}

export function createNixieCertificate(
  cluster: Provider,
  inputs: NixieCertificateInputs,
): Output<string> {
  const certificate = new Certificate(
    inputs.name,
    {
      accountKeyPem: inputs.account.accountKeyPem,
      commonName: inputs.hostname,
      keyType: 'EC256',

      // with 90-day certificates, an apply is due every 60 days
      minDaysRemaining: 30,

      // issued in the Pulumi run, so no DNS token enters the cluster
      dnsChallenges: [
        { provider: 'cloudflare', config: { CF_DNS_API_TOKEN: secret(inputs.dnsToken) } },
      ],
    },
    { provider: inputs.account.provider },
  );

  return createTLSSecret(cluster, inputs, certificate);
}

function createTLSSecret(
  cluster: Provider,
  inputs: NixieCertificateInputs,
  certificate: Certificate,
): Output<string> {
  const tls = new Secret(
    `${inputs.name}-tls`,
    {
      // no fixed name: a renewal replaces the Secret, and the Ingress follows the new name
      metadata: { namespace: inputs.namespace },
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
