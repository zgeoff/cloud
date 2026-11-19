import { FetchInterceptor } from '@mswjs/interceptors/fetch/web';
import { InterceptorSource, defineNetwork } from 'msw/experimental';
import type { HttpNetworkFrame, NetworkSource } from 'msw/experimental';
import { handlers } from './handlers.ts';

// msw/node answers a request at Node's sockets, which Bun's native fetch never opens, so its
// mocks miss every request (mswjs/msw#2811); the web interceptor patches the global fetch instead
const source: NetworkSource<HttpNetworkFrame> = new InterceptorSource({
  interceptors: [new FetchInterceptor()],
});

export const server = defineNetwork({ sources: [source], handlers, context: { quiet: true } });
