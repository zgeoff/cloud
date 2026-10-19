export const alloyPaths = {
  storage: '/var/lib/alloy',

  // the kubelet's layout: one directory per pod, named <namespace>_<pod>_<uid>, and one per
  // container inside it
  podLogs: '/var/log/pods',

  podLogPositionsSeed: '/var/lib/alloy/pod-log-positions.yml',

  // the positions file of loki.source.file "pods", in the directory Alloy names after it
  podLogPositions: '/var/lib/alloy/loki.source.file.pods/positions.yml',
};
