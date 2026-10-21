import type { NixieReadProcedure } from './nixie-procedure-kinds.ts';
import type { NixieInput } from './nixie-rpc.ts';

export type NixieAPICheckCall = {
  [Procedure in NixieReadProcedure]: {
    readonly procedure: Procedure;
    readonly input: NixieInput<Procedure>;
  };
}[NixieReadProcedure];

// The deploy check sends each call without a session, so nixie refuses it before the procedure
// runs. One call takes no input and one takes an input, so both of the adapter's encodings reach
// nixie.
export const nixieAPICheckCalls: readonly NixieAPICheckCall[] = [
  { procedure: 'sessions/list', input: undefined },
  { procedure: 'conversation/read', input: { thread: 'conversation', limit: 1 } },
];
