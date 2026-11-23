// Needs a zgeoff/cloud clone on a machine whose imp CLI calls the geoffcloud host with a
// manage-scope token.
import { homedir } from 'node:os';
import { createAgentImage } from './create-agent-image.ts';
import { subscribeToInterrupts } from './subscribe-to-interrupts.ts';

const trap = subscribeToInterrupts();

process.exitCode = await createAgentImage({
  ...trap,
  args: process.argv.slice(2),
  cwd: process.cwd(),
  home: homedir(),
  targetConfigs: (process.env['AGENT_IMAGE_TARGET_CONFIGS'] ?? '').split(':').filter(Boolean),
  buildTimeout: process.env['AGENT_IMAGE_BUILD_TIMEOUT'],
});

trap.unsubscribe();
