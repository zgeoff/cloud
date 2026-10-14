// The probe's target name for a daemon, which the probe's ServiceMonitor stamps on its
// series as the `target` label. geoffcloud's keeps the name it had as the only daemon,
// so its ServiceMonitor, its series and its alert stay as they were.
export function toATCDaemonProbeTarget(daemonName: string): string {
  return daemonName === 'geoffcloud' ? 'atc-daemon' : `atc-daemon-${daemonName}`;
}
