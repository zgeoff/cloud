import { serveIngest } from '@pepys/ingest';
import { deployment } from './deployment.ts';

// the entry that `bun build --compile` turns into the image's pepys-ingest
await serveIngest({ deployment, environment: process.env });
