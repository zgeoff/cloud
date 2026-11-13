import { pepysWorkloads } from '../shared/pepys-workloads.ts';

// nixie's Traefik holds the host's tailnet port 443, so pepys's tailnet route shares it
export function buildNixieRoutesNamespaces(pepysTailnetHostname: string | undefined): string[] {
  return pepysTailnetHostname === undefined ? ['nixie'] : ['nixie', pepysWorkloads.namespace];
}
