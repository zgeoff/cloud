import { all } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';

// a Service's name and namespace, as its metadata gives them
interface ServiceName {
  readonly name: Output<string>;
  readonly namespace: Output<string>;
}

// a Service's URL inside the cluster, which a pod reaches through the cluster's DNS
export function buildServiceURL(service: ServiceName, port: number): Output<string> {
  return all([service.name, service.namespace]).apply(
    ([name, namespace]) => `http://${name}.${namespace}.svc.cluster.local:${port}`,
  );
}
