// The labels of the pods that an egress allow selects. The backup jobs beside them carry none of
// these, so they stay refused.
export const podLabels = {
  atcGateway: { app: 'atc-gateway' },
  atcDaemonProbe: { app: 'atc-daemon-probe' },
  impHealthProbe: { app: 'imp-health-probe' },
  cloudflared: { app: 'cloudflared' },
} as const;
