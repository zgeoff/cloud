// A Pulumi program that create-cluster-provider.test.ts previews through the real engine. It takes
// the cluster's provider, rendering to files instead of a cluster, then declares the case's Helm
// chart and raw Roles from the directory GUARD_CASE_DIR names: chart/, and roles.json.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import { Role } from '@pulumi/kubernetes/rbac/v1';
import type { input } from '@pulumi/kubernetes/types';
import { createClusterProvider } from '../../cluster/index.ts';

const caseDir = process.env['GUARD_CASE_DIR'];

if (caseDir === undefined) {
  throw new Error('set GUARD_CASE_DIR to the case directory');
}

const provider = createClusterProvider('render', {
  renderYamlToDirectory: join(caseDir, 'render'),
});

const chart = existsSync(join(caseDir, 'chart'))
  ? new Chart('case', { chart: join(caseDir, 'chart'), namespace: 'atc' }, { provider })
  : undefined;

const roles = existsSync(join(caseDir, 'roles.json'))
  ? (JSON.parse(readFileSync(join(caseDir, 'roles.json'), 'utf8')) as input.rbac.v1.Role[]).map(
      (role, index) => new Role(`case-${String(index)}`, role, { provider }),
    )
  : [];

export const chartURN = chart?.urn;
export const roleURNs = roles.map((role) => role.urn);
