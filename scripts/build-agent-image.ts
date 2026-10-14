// Builds and checks the agent image for one commit on main, in one command, from a zgeoff/cloud
// clone on a machine whose imp CLI calls the geoffcloud host with a manage-scope token:
// `bun scripts/build-agent-image.ts [--keep] [<commit on main>]`.
import { createAgentImage } from './create-agent-image.ts';
import { subscribeToInterrupts } from './subscribe-to-interrupts.ts';

const trap = subscribeToInterrupts();

process.exitCode = await createAgentImage({
  ...trap,
  args: process.argv.slice(2),
  cwd: process.cwd(),
  buildTimeout: process.env['AGENT_IMAGE_BUILD_TIMEOUT'],
});

trap.unsubscribe();
