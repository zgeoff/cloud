// A Pulumi program that create-cluster-provider.test.ts previews through the real engine. It takes
// the cluster's provider, rendering to files instead of a cluster, then declares the case's Helm
// chart and raw Roles from the directory GUARD_CASE_DIR names: chart/, and roles.json.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Chart } from '@pulumi/kubernetes/helm/v4';
import { Role } from '@pulumi/kubernetes/rbac/v1';
import { z } from 'zod';
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

const ruleSchema = z.object({
  apiGroups: z.array(z.string()),
  resources: z.array(z.string()),
  verbs: z.array(z.string()),
});

const metadataSchema = z.object({ name: z.string(), namespace: z.string() });
const rolesSchema = z.array(z.object({ metadata: metadataSchema, rules: z.array(ruleSchema) }));
const rolesPath = join(caseDir, 'roles.json');

const roleArgs = existsSync(rolesPath)
  ? rolesSchema.parse(JSON.parse(readFileSync(rolesPath, 'utf8')))
  : [];

const roles = roleArgs.map((role, index) => new Role(`case-${String(index)}`, role, { provider }));

export const chartURN = chart?.urn;
export const roleURNs = roles.map((role) => role.urn);
