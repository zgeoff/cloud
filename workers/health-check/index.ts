// External health check for geoff.cloud (#8): the Worker's entry module. Workers calls
// scheduled on the cron; the check logs each change of state to the console.
import { makeScheduledHandler } from './make-scheduled-handler.ts';

const handler = {
  scheduled: makeScheduledHandler(console),
};

export default handler;
