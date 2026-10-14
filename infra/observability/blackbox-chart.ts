// the Prometheus blackbox exporter's chart, pinned once for every probe release; bump deliberately
export const blackboxChart = {
  chart: 'prometheus-blackbox-exporter',
  version: '11.19.1',
  repositoryOpts: { repo: 'https://prometheus-community.github.io/helm-charts' },
};
