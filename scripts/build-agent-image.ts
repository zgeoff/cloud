// Builds and checks the agent image for one commit on main, in one command, from a zgeoff/cloud
// clone on a machine whose imp CLI calls the geoffcloud host with a manage-scope token:
// `bun scripts/build-agent-image.ts [--keep] [<commit on main>]`.
import { createAgentImage } from './create-agent-image.ts';
import { runProcess } from './run-process.ts';

process.exitCode = await createAgentImage({
  args: process.argv.slice(2),
  cwd: process.cwd(),
  buildTimeout: process.env['AGENT_IMAGE_BUILD_TIMEOUT'],
  run: runProcess,
  printOut: (text) => {
    process.stdout.write(text);
  },
  printErr: (text) => {
    process.stderr.write(text);
  },
});
