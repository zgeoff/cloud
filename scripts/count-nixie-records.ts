import type { RPCResult } from './send-nixie-rpc.ts';
import { sendNixieRPC } from './send-nixie-rpc.ts';

export interface NixieSession {
  readonly url: string;
  readonly token: string;
}

export interface RecordCount {
  readonly records: number;

  // the log sequence the newest page was read at, which a stream follows from
  readonly readAtSequence: number;
}

// Counts the records of nixie's conversation thread, reading it newest page first, each page
// ending where the one before it began. It only reads.
export function countNixieRecords(
  session: Readonly<NixieSession>,
): Promise<RPCResult<RecordCount>> {
  return countPages(session, { beforeSequence: undefined, count: undefined });
}

interface Cursor {
  readonly beforeSequence: number | undefined;
  readonly count: RecordCount | undefined;
}

interface ThreadPage {
  readonly hasEarlier: boolean;
  readonly readAtSequence: number;
  readonly records: readonly { readonly sequence: number }[];
}

// nixie's largest page
const pageLimit = 200;

async function countPages(
  session: Readonly<NixieSession>,
  cursor: Readonly<Cursor>,
): Promise<RPCResult<RecordCount>> {
  const page = await sendNixieRPC<ThreadPage>({
    url: session.url,
    token: session.token,
    procedure: 'conversation/read',
    input: {
      thread: 'conversation',
      limit: pageLimit,
      ...(cursor.beforeSequence === undefined ? {} : { beforeSequence: cursor.beforeSequence }),
    },
  });

  if (!page.ok) {
    return page;
  }

  const count = {
    records: (cursor.count?.records ?? 0) + page.value.records.length,
    readAtSequence: cursor.count?.readAtSequence ?? page.value.readAtSequence,
  };

  const [oldest] = page.value.records;

  return page.value.hasEarlier && oldest !== undefined
    ? countPages(session, { beforeSequence: oldest.sequence, count })
    : { ok: true, value: count };
}
