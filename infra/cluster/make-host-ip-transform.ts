import type { ProviderResource, ResourceTransform } from '@pulumi/pulumi';

export function makeHostIPTransform(
  hostIP: string,
  portName: string,
  provider: ProviderResource,
): ResourceTransform {
  // returned opts replace the child's whole, dropping the provider it inherits from the chart, so
  // only the Deployment returns any and names that provider again
  return (args) =>
    args.type === 'kubernetes:apps/v1:Deployment'
      ? {
          props: buildBoundProps(args.props, hostIP, portName),
          opts: { ...args.opts, provider },
        }
      : undefined;
}

type Fields = Record<string, unknown>;

function buildBoundProps(props: Fields, hostIP: string, portName: string): Fields {
  // copies only the objects on the path to the ports: a chart child's props can hold Outputs,
  // which carry functions and cannot be cloned
  return buildWithField(props, 'spec', (spec) =>
    buildWithNested(spec, 'template', (template) =>
      buildWithNested(template, 'spec', (podSpec) =>
        buildWithNested(podSpec, 'containers', (containers) =>
          buildMappedRecords(containers, (container) =>
            buildWithField(container, 'ports', (ports) =>
              buildMappedRecords(ports, (port) =>
                // Traefik's chart also writes its hostIP value into the entry point's listen
                // address, which a pod cannot bind, so the host address goes on the port instead
                port['name'] === portName ? { ...port, hostIP } : port,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

function buildWithField(value: Fields, key: string, change: (field: unknown) => unknown): Fields {
  return key in value ? { ...value, [key]: change(value[key]) } : value;
}

function buildWithNested(
  value: unknown,
  key: string,
  change: (field: unknown) => unknown,
): unknown {
  // a value that is not a plain object, such as an Output during a preview, passes through whole
  return isFields(value) ? buildWithField(value, key, change) : value;
}

function buildMappedRecords(value: unknown, change: (record: Fields) => Fields): unknown {
  return Array.isArray(value)
    ? value.map((item: unknown) => (isFields(item) ? change(item) : item))
    : value;
}

function isFields(value: unknown): value is Fields {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }

  const prototype: unknown = Object.getPrototypeOf(value);

  return prototype === Object.prototype || prototype === null;
}
