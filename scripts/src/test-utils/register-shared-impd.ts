import { afterAll, beforeAll } from 'bun:test';
import { startSharedScriptsImpd, stopScriptsImpd } from './start-scripts-impd.ts';

// each file gets one impd that its tests share, started here so the start stays out of the first
// test's time limit, and stopped with the file
beforeAll(startSharedScriptsImpd);
afterAll(stopScriptsImpd);
