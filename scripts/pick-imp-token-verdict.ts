import { findJSONField } from './find-json-field.ts';

// scripts/host/check-atc-imp-token.sh exits 121 for a file atc cannot use and 120 for one it
// cannot read; otherwise its exit is curl's, or ssh's 255, and its stdout is impd's answer, then a
// line with the HTTP status
export interface ImpTokenCheck {
  readonly exitCode: number;
  readonly stdout: string;
}

// 'good', 'bad', or why the saved token stays unchecked. Only a file atc cannot use, impd's 401
// for an unknown token, or a clear answer naming another caller means the file is bad.
export function pickImpTokenVerdict(check: Readonly<ImpTokenCheck>): string {
  if (check.exitCode === 121) {
    return 'bad';
  }

  if (check.exitCode === 120) {
    return 'the saved token is not a readable regular file on the host';
  }

  if (check.exitCode !== 0) {
    return `the check on the host exited ${check.exitCode} (curl's exit code, or 255 from ssh)`;
  }

  return pickAnswerVerdict(check.stdout);
}

function pickAnswerVerdict(answer: string) {
  const split = answer.lastIndexOf('\n');
  const status = answer.slice(split + 1);

  if (status === '401') {
    return 'bad';
  }

  return /^2\d\d$/u.test(status)
    ? pickIdentityVerdict(status, answer.slice(0, Math.max(split, 0)))
    : `impd answered HTTP ${status}`;
}

function pickIdentityVerdict(status: string, body: string) {
  const identity = findJSONField(parseBody(body), 'json');
  const kind = findJSONField(identity, 'kind');
  const name = findJSONField(identity, 'name');

  if (typeof kind !== 'string' || typeof name !== 'string') {
    return `impd answered HTTP ${status} without an identity`;
  }

  return kind === 'token' && name === 'atc-cloud' ? 'good' : 'bad';
}

function parseBody(body: string): unknown {
  try {
    const value: unknown = JSON.parse(body);

    return value;
  } catch {
    return undefined;
  }
}
