import { pepysWorkloads } from '../shared/pepys-workloads.ts';

// nixie's Traefik holds the host's tailnet port 443, so pepys's tailnet routes share it
export function buildNixieRoutesNamespaces(hasPepysTailnetRoute: boolean): string[] {
  return hasPepysTailnetRoute ? ['nixie', pepysWorkloads.namespace] : ['nixie'];
}
