import { createTestNetwork } from '@zgeoff/testing/fetch';

// No default handlers: each test and stand-in registers its own with network.use.
export const network = createTestNetwork({ handlers: [] });
