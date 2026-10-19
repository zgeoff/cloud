// The paths Alloy's config and its pod share, as the node mounts them.
export const alloyPaths = {
  // Alloy's storage, such as its read positions, on a directory of the node
  storage: '/var/lib/alloy',

  // the kubelet's pod log directories, under /var/log: one directory per pod, named
  // <namespace>_<pod>_<uid>, and one per container inside it
  podLogs: '/var/log/pods',

  // the read positions that seed Alloy's pod-log source when it has none of its own
  podLogPositionsSeed: '/var/lib/alloy/pod-log-positions.yml',
};
