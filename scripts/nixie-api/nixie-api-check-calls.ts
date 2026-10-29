import type { NixieInput, NixieProcedure } from './nixie-rpc.ts';

export type NixieAPICheckCall = {
  [Procedure in NixieProcedure]: {
    readonly procedure: Procedure;
    readonly input: NixieInput<Procedure>;
  };
}[NixieProcedure];

// The deploy check sends each call without a session, so nixie refuses it before the procedure
// runs. If nixie's auth breaks, the call runs for real, so each call must only read. One call takes
// no input and one takes an input, so both of the adapter's encodings reach nixie.
export const nixieAPICheckCalls: readonly NixieAPICheckCall[] = [
  { procedure: 'sessions/list', input: undefined },
  { procedure: 'conversation/read', input: { thread: 'conversation', limit: 1 } },
];
