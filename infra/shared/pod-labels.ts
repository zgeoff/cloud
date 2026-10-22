// the backup jobs beside these pods carry none of these labels, so they stay refused
export const podLabels = {
  atcGateway: { app: 'atc-gateway' },
  atcDaemonProbe: { app: 'atc-daemon-probe' },
  impHealthProbe: { app: 'imp-health-probe' },
  cloudflared: { app: 'cloudflared' },
  nixie: { app: 'nixie' },
} as const;
