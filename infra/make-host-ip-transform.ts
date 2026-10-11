import type { ResourceTransform } from '@pulumi/pulumi';

// the parts of a rendered Deployment this changes; chart children carry plain values, never Outputs
interface DeploymentProps {
  spec: {
    template: {
      spec: { containers: { ports?: { name?: string; hostIP?: string }[] }[] };
    };
  };
}

// Makes a transform that binds one named container port of a chart's Deployment to a host address.
// Traefik's chart also writes its hostIP value into the entry point's listen address, which a pod
// cannot bind, so the host address goes on the rendered port instead. Other resources pass through.
export function makeHostIPTransform(hostIP: string, portName: string): ResourceTransform {
  return (args) => {
    if (args.type !== 'kubernetes:apps/v1:Deployment') {
      return;
    }

    const props = structuredClone(args.props) as DeploymentProps;
    const ports = props.spec.template.spec.containers.flatMap((container) => container.ports ?? []);

    for (const port of ports.filter((candidate) => candidate.name === portName)) {
      port.hostIP = hostIP;
    }

    return { props, opts: args.opts };
  };
}
