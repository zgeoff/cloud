// the appVersion of chart 41.6.0; bump with the chart
const traefikVersion = 'v3.7.13';
const traefikDigest = 'sha256:24841fe2de7304c149343d877d2923b4c8800a38ba015dea9174c23b20e344a0';

export interface NixieIngressValuesInputs {
  readonly httpsPort: number;

  // Pulumi waits on each Ingress's status address, and the ClusterIP Service has none to publish
  readonly endpointIP: string;
  readonly ingressClass: string;
  readonly namespace: string;
}

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
      kubernetesIngress: {
        enabled: true,
        namespaces: [inputs.namespace],
        publishedService: { enabled: false },
        ingressEndpoint: { ip: inputs.endpointIP },
      },
    },
    ports: {
      web: { expose: { default: false } },
      websecure: { hostPort: inputs.httpsPort },
    },
    service: { spec: { type: 'ClusterIP' } },
  };
}
