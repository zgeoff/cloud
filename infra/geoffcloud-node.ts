// The host's own tailnet node (geoffcloud, tag:cloud). A long-lived node, so its address is stable.
// nixie's ingress binds 443 on this address alone, and nixie.geoff.cloud points at it.
export const geoffcloudNode = {
  ip: '100.69.47.33',
  httpsPort: 443,
};
