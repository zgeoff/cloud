import { buildBoxxyPlugin } from '@boxxy/pepys';
import { defineDeployment } from '@pepys/kit';
import { githubDelivery, githubPlugin, githubPullRequestConsumer } from '@pepys/source-github';
import {
  telemetryModelRequestConsumer,
  telemetryPlugin,
  telemetryTurnCostConsumer,
} from '@pepys/source-telemetry';

// boxxy's queries read the tables of the GitHub and telemetry consumers, so its plug-in takes
// their declarations, and the deployment lists their plug-ins beside it
const boxxyPlugin = buildBoxxyPlugin({
  telemetryModelRequest: telemetryModelRequestConsumer,
  telemetryTurnCost: telemetryTurnCostConsumer,
  githubPullRequest: githubPullRequestConsumer,
  delivery: githubDelivery,
});

// The deployment that the cloud-pepys image runs: `pepys build` compiles its consumers into the
// image's modules, and ingest and the API serve it. deploy/pepys/ingest-routes.json must match its
// routes and variables, which scripts/check-pepys-routes.ts checks before each image build.
export const deployment = defineDeployment({
  name: 'cloud',
  plugins: [githubPlugin, telemetryPlugin, boxxyPlugin],
});
