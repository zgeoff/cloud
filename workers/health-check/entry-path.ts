import { fileURLToPath } from 'node:url';

// The module Workers loads, which infra bundles at deploy time
export const entryPath = fileURLToPath(new URL('index.ts', import.meta.url));
