import { setupServer } from 'msw/node';
import { handlers } from './handlers.ts';

// The one MSW server for the health-check worker's HTTP boundary; the preload runs it
export const server = setupServer(...handlers);
