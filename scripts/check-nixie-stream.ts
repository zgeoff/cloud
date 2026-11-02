import type { NixieSession, RecordCount } from './count-nixie-records.ts';
import { countNixieRecords } from './count-nixie-records.ts';
import { findJSONField } from './find-json-field.ts';
import type { NixieOutput } from './nixie-api/nixie-rpc.ts';
import type { StreamReport } from './read-nixie-stream.ts';
import { readNixieStream } from './read-nixie-stream.ts';
import { sendNixieRPC } from './send-nixie-rpc.ts';

interface RemoteResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

export interface CheckNixieStreamOptions {
  readonly url: string;

  readonly holdMs: number;
  readonly maxGapMs: number;
  readonly minKeepalives: number;

  // the line lands in the host's journal, so it never carries a secret
  readonly runRemote: (command: string) => Promise<RemoteResult>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export async function checkNixieStream(
  options: Readonly<CheckNixieStreamOptions>,
): Promise<number> {
  const session = await createCheckSession(options);

  if (session === undefined) {
    return 1;
  }

  const passed = await checkStream(options, session).catch((error: unknown) => {
    options.printErr(`check-nixie-stream: the check stopped: ${String(error)}\n`);

    return false;
  });

  const revoked = await removeCheckSession(options, session);

  if (!passed || !revoked) {
    return 1;
  }

  options.printOut('stream check passed\n');

  return 0;
}

interface CheckSession extends NixieSession {
  readonly sessionID: string;
}

async function createCheckSession(
  options: Readonly<CheckNixieStreamOptions>,
): Promise<CheckSession | undefined> {
  const code = await readEnrolmentCode(options);

  if (code === undefined) {
    return undefined;
  }

  const enrolled = await sendNixieRPC({
    url: options.url,
    token: null,
    procedure: 'sessions/enrol',
    input: {
      clientActionID: crypto.randomUUID(),
      code,
      deviceName: 'deploy check',
      tokenDelivery: 'bearer',
    },
    parse: parseEnrolment,
  });

  if (!enrolled.ok) {
    options.printErr(`check-nixie-stream: cannot enrol a check session: ${enrolled.error}\n`);

    return undefined;
  }

  options.printOut(`enrolled check session ${enrolled.value.sessionID}\n`);

  return { url: options.url, token: enrolled.value.token, sessionID: enrolled.value.sessionID };
}

async function readEnrolmentCode(
  options: Readonly<CheckNixieStreamOptions>,
): Promise<string | undefined> {
  const result = await options.runRemote(enrolCodeCommand);

  // enrol-code prints the code on its first line, then a line that says until when it works
  const [firstLine = ''] = result.stdout.split('\n');
  const code = firstLine.trim();

  if (result.exitCode === 0 && code !== '' && !/\s/u.test(code)) {
    return code;
  }

  options.printErr(
    `check-nixie-stream: cannot get an enrolment code (exit ${result.exitCode}): ${result.stderr.trim()}\n`,
  );

  return undefined;
}

function parseEnrolment(
  output: unknown,
): (NixieOutput<'sessions/enrol'> & { readonly token: string }) | undefined {
  const sessionID = findJSONField(output, 'sessionID');
  const token = findJSONField(output, 'token');

  // the contract leaves token optional because a cookie enrolment answers none
  return typeof sessionID === 'string' && typeof token === 'string'
    ? { sessionID, token }
    : undefined;
}

const enrolCodeCommand = 'k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie enrol-code';

async function checkStream(
  options: Readonly<CheckNixieStreamOptions>,
  session: Readonly<CheckSession>,
): Promise<boolean> {
  const before = await printCount(options, session, 'before');

  if (before === undefined) {
    return false;
  }

  const stream = await readNixieStream({
    ...session,

    // the stream follows from the first count's sequence, so any record it carries is new
    afterSequence: before.readAtSequence,
    holdMs: options.holdMs,
  });

  if (!stream.ok) {
    options.printErr(`check-nixie-stream: cannot open the stream: ${stream.error}\n`);

    return false;
  }

  options.printOut(`${formatStream(stream.value)}\n`);

  const after = await printCount(options, session, 'after');

  return (
    after !== undefined &&
    printFailures(options, collectFailures({ options, stream: stream.value, before, after }))
  );
}

async function printCount(
  options: Readonly<CheckNixieStreamOptions>,
  session: Readonly<CheckSession>,
  when: 'before' | 'after',
): Promise<RecordCount | undefined> {
  const count = await countNixieRecords(session);

  if (!count.ok) {
    options.printErr(
      `check-nixie-stream: cannot count the conversation's records ${when}: ${count.error}\n`,
    );

    return undefined;
  }

  options.printOut(`conversation records ${when}: ${count.value.records}\n`);

  return count.value;
}

function formatStream(report: StreamReport): string {
  return `stream ${report.end} for ${formatSeconds(report.openMs)}: ${report.keepalives} keepalives, longest wait ${formatSeconds(report.longestGapMs)}, ${report.records} records`;
}

function formatSeconds(durationMs: number): string {
  return `${(durationMs / 1000).toFixed(1)} s`;
}

function printFailures(
  options: Readonly<CheckNixieStreamOptions>,
  failures: readonly string[],
): boolean {
  for (const failure of failures) {
    options.printErr(`check-nixie-stream: ${failure}\n`);
  }

  return failures.length === 0;
}

interface Outcome {
  readonly options: Readonly<CheckNixieStreamOptions>;
  readonly stream: StreamReport;
  readonly before: RecordCount;
  readonly after: RecordCount;
}

function collectFailures(outcome: Outcome): string[] {
  const failures = [
    outcome.stream.end === 'held' ? null : `the stream did not stay open: ${outcome.stream.end}`,
    outcome.stream.longestGapMs <= outcome.options.maxGapMs
      ? null
      : `the stream went more than ${formatSeconds(outcome.options.maxGapMs)} without a keepalive`,
    outcome.stream.keepalives >= outcome.options.minKeepalives
      ? null
      : `the stream carried ${outcome.stream.keepalives} keepalives, fewer than ${outcome.options.minKeepalives}`,
    outcome.stream.records === 0
      ? null
      : `the stream carried ${outcome.stream.records} new records`,
    outcome.after.records === outcome.before.records
      ? null
      : `the conversation went from ${outcome.before.records} to ${outcome.after.records} records`,
  ];

  return failures.filter((failure) => failure !== null);
}

async function removeCheckSession(
  options: Readonly<CheckNixieStreamOptions>,
  session: Readonly<CheckSession>,
): Promise<boolean> {
  const revoked = await sendNixieRPC({
    url: session.url,
    token: session.token,
    procedure: 'sessions/revoke',
    input: { clientActionID: crypto.randomUUID(), sessionID: session.sessionID },
    parse: (output) => output,
  });

  if (!revoked.ok) {
    options.printErr(
      `check-nixie-stream: cannot revoke check session ${session.sessionID}: ${revoked.error}; revoke it from nixie's device list\n`,
    );

    return false;
  }

  options.printOut(`revoked check session ${session.sessionID}\n`);

  return true;
}

async function runSSH(command: string): Promise<RemoteResult> {
  const subprocess = Bun.spawn(['ssh', 'root@geoffcloud', command], {
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(subprocess.stdout).text(),
    new Response(subprocess.stderr).text(),
    subprocess.exited,
  ]);

  return { exitCode, stdout, stderr };
}

if (import.meta.main) {
  process.exitCode = await checkNixieStream({
    url: process.argv[2] ?? 'https://nixie.geoff.cloud',

    // nixie sends a keepalive every 5 s, and its web client counts a stream that misses three in a
    // row as dead
    holdMs: 30_000,
    maxGapMs: 15_000,
    minKeepalives: 5,
    runRemote: runSSH,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
