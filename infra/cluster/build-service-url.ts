import { all } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';

interface ServiceName {
  readonly name: Output<string>;
  readonly namespace: Output<string>;
}

export function buildServiceURL(service: ServiceName, port: number): Output<string> {
  return all([service.name, service.namespace]).apply(
    ([name, namespace]) => `http://${name}.${namespace}.svc.cluster.local:${port}`,
  );
}
