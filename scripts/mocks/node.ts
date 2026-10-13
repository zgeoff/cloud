import { setupServer } from 'msw/node';

// The one MSW server for the scripts' HTTP boundary; the preload runs it. It has no default
// handlers: each test and stand-in registers its own with server.use.
export const server = setupServer();
