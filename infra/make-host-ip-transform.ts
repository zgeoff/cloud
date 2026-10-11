import type { ResourceTransform } from '@pulumi/pulumi';

// Makes a transform that binds one named container port of a chart's Deployment to a host address.
// Traefik's chart also writes its hostIP value into the entry point's listen address, which a pod
// cannot bind, so the host address goes on the rendered port instead. Other resources pass through.
export function makeHostIPTransform(hostIP: string, portName: string): ResourceTransform {
  return (args) => {
    // chart children carry plain values, never Outputs, so a structured clone copies them whole
    const props = structuredClone(args.props);

    if (args.type === 'kubernetes:apps/v1:Deployment') {
      for (const port of collectPorts(props).filter(
        (candidate) => candidate['name'] === portName,
      )) {
        port['hostIP'] = hostIP;
      }
    }

    return { props, opts: args.opts };
  };
}

type Fields = Record<string, unknown>;

// every container port of a Deployment's pod template, or none when the shape differs
function collectPorts(props: unknown): Fields[] {
  const template = getField(getField(props, 'spec'), 'template');
  const containers = getField(getField(template, 'spec'), 'containers');

  return toRecords(containers).flatMap((container) => toRecords(container['ports']));
}

function getField(value: unknown, key: string): unknown {
  return isFields(value) ? value[key] : undefined;
}

function toRecords(value: unknown): Fields[] {
  const items: unknown[] = Array.isArray(value) ? value : [];

  return items.filter((item) => isFields(item));
}

function isFields(value: unknown): value is Fields {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
