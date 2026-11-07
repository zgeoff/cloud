import type { oss } from '@pulumiverse/grafana';

export function buildMCPAccountArgs(): oss.ServiceAccountArgs {
  return { name: 'mcp-viewer', role: 'Viewer' };
}
