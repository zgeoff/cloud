import { fileURLToPath } from 'node:url';

export const entryPath = fileURLToPath(new URL('index.ts', import.meta.url));
