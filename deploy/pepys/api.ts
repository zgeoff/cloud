import { serveAPI } from '@pepys/api';
import { deployment } from './deployment.ts';

// the entry that `bun build --compile` turns into the image's pepys-api; with no arguments it
// serves, and with an admin command, such as `passkeys enroll`, it runs that command and exits
serveAPI({ deployment, environment: process.env, argv: process.argv.slice(2) });
