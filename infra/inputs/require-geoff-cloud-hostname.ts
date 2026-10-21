// a host name in the geoff.cloud zone, where Pulumi manages the DNS records
const hostnamePattern = /^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+geoff\.cloud$/u;

export function requireGeoffCloudHostname(
  key: string,
  hostname: string | undefined,
): asserts hostname is string {
  if (hostname === undefined || !hostnamePattern.test(hostname)) {
    throw new Error(`stack config "${key}" must name a host under geoff.cloud`);
  }
}
