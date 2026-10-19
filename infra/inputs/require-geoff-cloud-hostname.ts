// a host name in the geoff.cloud zone, where Pulumi manages the DNS records
const hostnamePattern = /^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+geoff\.cloud$/u;

// Throws unless the stack config value at key, such as "nixie.hostname", names a host under
// geoff.cloud.
export function requireGeoffCloudHostname(
  key: string,
  hostname: string | undefined,
): asserts hostname is string {
  if (hostname === undefined || !hostnamePattern.test(hostname)) {
    throw new Error(`stack config "${key}" must name a host under geoff.cloud`);
  }
}
