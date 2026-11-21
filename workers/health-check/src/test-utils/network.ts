import { createTestNetwork } from '@zgeoff/testing/fetch';
import { handlers } from './handlers.ts';

export const network = createTestNetwork({ handlers });
