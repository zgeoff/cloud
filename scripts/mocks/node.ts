import { setupServer } from 'msw/node';

// No default handlers: each test and stand-in registers its own with server.use.
export const server = setupServer();
