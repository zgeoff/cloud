import { serveAPI } from '@pepys/api';
import { deployment } from './deployment.ts';

// the entry that `bun build --compile` turns into the image's pepys-api
serveAPI({ deployment, environment: process.env });
