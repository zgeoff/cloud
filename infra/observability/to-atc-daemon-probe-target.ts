export function toATCDaemonProbeTarget(daemonName: string): string {
  // geoffcloud's keeps its bare name, so its ServiceMonitor, its series and its alert stay as they
  // were.
  return daemonName === 'geoffcloud' ? 'atc-daemon' : `atc-daemon-${daemonName}`;
}
