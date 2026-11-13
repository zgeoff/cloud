import { startServer } from '@boxxy/server';
import type { RunningServer } from '@boxxy/server';

// The boxxy server's entry in the cloud-boxxy image, which scripts/write-boxxy-image-context.sh
// compiles to one binary. The server reads its configuration file from BOXXY_CONFIG and its tokens
// from the environment; it exits 1 with a message that names each missing value, never a secret.
const answer = await startServer({
  env: process.env,
  log: {
    warn: (message, fields) => {
      console.warn(JSON.stringify({ level: 'warn', message, ...fields }));
    },
  },
});

if (answer.kind === 'refused') {
  console.error(answer.message);
  process.exit(1);
}

const server = answer.server;

console.log(
  JSON.stringify({
    level: 'info',
    message: 'boxxy server listening',
    ownerPort: server.ownerPort,
    workerPort: server.workerPort,

    // null without a public door
    publicPort: server.publicPort,
  }),
);

// Kubernetes stops the pod with SIGTERM: the server stops its tick and its listeners and closes
// the store before the process exits
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    void stopAndExit(server);
  });
}

async function stopAndExit(running: RunningServer): Promise<void> {
  await running.stop();

  process.exit(0);
}
