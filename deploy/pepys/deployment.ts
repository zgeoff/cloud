import { defineDeployment } from '@pepys/kit';
import { githubPlugin } from '@pepys/source-github';
import { telemetryPlugin } from '@pepys/source-telemetry';

// The deployment that the cloud-pepys image runs: `pepys build` compiles its consumers into the
// image's modules, and ingest and the API serve it. deploy/pepys/ingest-routes.json must match its
// routes and variables, which scripts/check-pepys-routes.ts checks before each image build.
export const deployment = defineDeployment({
  name: 'cloud',
  plugins: [githubPlugin, telemetryPlugin],
});
