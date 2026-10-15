import { setupServer } from 'msw/node';
import { handlers } from './handlers.ts';

// The one MSW server for the preview service's GitHub boundary; the preload runs it
export const server = setupServer(...handlers);
