import type { NixieProcedure } from './nixie-rpc.ts';

// nixie's contract marks no procedure read-only. A write takes a client action ID, issues or enrols
// a session, or answers a memory proposal, which takes no client action ID at its top level. A
// procedure that a nixie bump adds fails the type check until it has a kind here.
export const nixieProcedureKinds = {
  'conversation/read': 'read',
  'conversation/send': 'write',
  'conversation/readImage': 'read',
  'conversation/forget': 'write',
  'memory/readVersions': 'read',
  'memory/readRatingNotes': 'read',
  'memory/writerStatus': 'read',
  'memory/consolidatorStatus': 'read',
  'memory/listItems': 'read',
  'memory/findItems': 'read',
  'memory/readPinnedCore': 'read',
  'memory/readItem': 'read',
  'memory/retire': 'write',
  'memory/restore': 'write',
  'memory/previewForget': 'read',
  'memory/forget': 'write',
  'memory/previewForgetRetired': 'read',
  'memory/forgetRetired': 'write',
  'memory/readForgetStatus': 'read',
  'memory/pin': 'write',
  'memory/markSensitive': 'write',
  'memory/keep': 'write',
  'memory/undo': 'write',
  'memory/listNotices': 'read',
  'memory/listProposals': 'read',
  'memory/approveProposals': 'write',
  'memory/rejectProposals': 'write',
  'memory/export': 'write',
  'memory/keepMoment': 'write',
  'memory/listMoments': 'read',
  'memory/readMoment': 'read',
  'memory/readMomentSpan': 'read',
  'memory/editMoment': 'write',
  'memory/linkMoment': 'write',
  'memory/previewMomentDestroy': 'read',
  'memory/destroyMoment': 'write',
  'log/follow': 'read',
  'records/follow': 'read',
  'sessions/enrol': 'write',
  'sessions/issueCode': 'write',
  'sessions/list': 'read',
  'sessions/revoke': 'write',
} as const satisfies Record<NixieProcedure, 'read' | 'write'>;

export type NixieReadProcedure = {
  [Procedure in NixieProcedure]: (typeof nixieProcedureKinds)[Procedure] extends 'read'
    ? Procedure
    : never;
}[NixieProcedure];
