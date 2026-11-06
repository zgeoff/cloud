import { interpolate, secret } from '@pulumi/pulumi';
import type { Output } from '@pulumi/pulumi';
import type { ProviderArgs } from '@pulumiverse/grafana';

interface GrafanaProviderArgs extends ProviderArgs {
  readonly url: string;
  readonly auth: Output<string>;
}

export function buildGrafanaProviderArgs(
  url: string,
  adminPassword: Output<string>,
): GrafanaProviderArgs {
  return { url, auth: secret(interpolate`admin:${adminPassword}`) };
}
