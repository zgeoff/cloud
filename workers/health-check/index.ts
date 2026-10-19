import { makeScheduledHandler } from './make-scheduled-handler.ts';

const handler = {
  scheduled: makeScheduledHandler(console),
};

export default handler;
