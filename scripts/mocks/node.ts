import { FetchInterceptor } from '@mswjs/interceptors/fetch/web';
import { InterceptorSource, defineNetwork } from 'msw/experimental';

// msw/node answers a request at Node's sockets, which Bun's native fetch never opens, so its
// mocks miss every request (mswjs/msw#2811); the web interceptor patches the global fetch instead.
// No default handlers: each test and stand-in registers its own with server.use.
export const server = defineNetwork({
  sources: [new InterceptorSource({ interceptors: [new FetchInterceptor()] })],
  context: { quiet: true },
});
