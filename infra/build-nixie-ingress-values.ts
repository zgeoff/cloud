// Traefik's image, by digest: the appVersion of chart 41.6.0; bump with the chart
const traefikVersion = 'v3.7.13';
const traefikDigest = 'sha256:24841fe2de7304c149343d877d2923b4c8800a38ba015dea9174c23b20e344a0';

export interface NixieIngressValuesInputs {
  // the host port for HTTPS; makeHostIPTransform binds it to the host's tailnet address
  readonly httpsPort: number;

  // the ingress class nixie's Ingress names, and the one namespace Traefik watches
  readonly ingressClass: string;
  readonly namespace: string;
}

// Values for Traefik's Helm chart: one replica that holds the host's port 443, reads Ingress
// objects in nixie's namespace alone, and takes TLS from each Ingress's Secret, so it holds no
// ACME account or DNS token.
export function buildNixieIngressValues(inputs: NixieIngressValuesInputs): Record<string, unknown> {
  return {
    image: { digest: traefikDigest },
    versionOverride: traefikVersion,
    deployment: { replicas: 1 },

    // the hostPort is held by one pod at a time, so a rollout stops the old pod first
    updateStrategy: { type: 'RollingUpdate', rollingUpdate: { maxUnavailable: 1, maxSurge: 0 } },
    ingressClass: { enabled: true, isDefaultClass: false, name: inputs.ingressClass },
    gateway: { enabled: false },
    gatewayClass: { enabled: false },
    api: { dashboard: false },
    providers: {
      kubernetesCRD: { enabled: false },
      kubernetesGateway: { enabled: false },
      kubernetesIngress: { enabled: true, namespaces: [inputs.namespace] },
    },
    ports: {
      web: { expose: { default: false } },
      websecure: { hostPort: inputs.httpsPort },
    },
    service: { spec: { type: 'ClusterIP' } },
  };
}
