import { findJSONField } from './find-json-field.ts';
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

// nixie's largest page
const pageLimit = 200;

async function countPages(
  session: Readonly<NixieSession>,
  cursor: Readonly<Cursor>,
): Promise<RPCResult<RecordCount>> {
  const page = await sendNixieRPC({
    url: session.url,
    token: session.token,
    procedure: 'conversation/read',
    input: {
      thread: 'conversation',
      limit: pageLimit,
      ...(cursor.beforeSequence === undefined ? {} : { beforeSequence: cursor.beforeSequence }),
    },
    parse: parsePage,
  });

  if (!page.ok) {
    return page;
  }

  const count = {
    records: (cursor.count?.records ?? 0) + page.value.records,
    readAtSequence: cursor.count?.readAtSequence ?? page.value.readAtSequence,
  };

  return page.value.hasEarlier && page.value.oldestSequence !== undefined
    ? countPages(session, { beforeSequence: page.value.oldestSequence, count })
    : { ok: true, value: count };
}

interface Page {
  readonly hasEarlier: boolean;
  readonly readAtSequence: number;
  readonly records: number;

  // the first record's sequence, which the next page ends before
  readonly oldestSequence: number | undefined;
}

function parsePage(output: unknown): Page | undefined {
  const hasEarlier = findJSONField(output, 'hasEarlier');
  const readAtSequence = findJSONField(output, 'readAtSequence');
  const records = findJSONField(output, 'records');

  if (
    typeof hasEarlier !== 'boolean' ||
    typeof readAtSequence !== 'number' ||
    !Array.isArray(records)
  ) {
    return undefined;
  }

  const oldest: unknown = findJSONField(records.at(0), 'sequence');

  return {
    hasEarlier,
    readAtSequence,
    records: records.length,
    oldestSequence: typeof oldest === 'number' ? oldest : undefined,
  };
}
