import { findJSONField } from './find-json-field.ts';

// scripts/host/check-atc-imp-token.sh exits 121 for a file atc cannot use, 120 for one it cannot
// read and 122 for a token impd refuses; otherwise its exit is imp's CLI's, or ssh's 255, and its
// stdout is the CLI's `token whoami --json` answer
export interface ImpTokenCheck {
  readonly exitCode: number;
  readonly stdout: string;
}

// 'good', 'bad', or why the saved token stays unchecked. Only a file atc cannot use, impd's 401
// for an unknown token, or a clear answer naming another caller means the file is bad.
export function pickImpTokenVerdict(check: Readonly<ImpTokenCheck>): string {
  if (check.exitCode === 121 || check.exitCode === 122) {
    return 'bad';
  }

  if (check.exitCode === 120) {
    return 'the saved token is not a readable regular file on the host';
  }

  if (check.exitCode !== 0) {
    return `the check on the host exited ${check.exitCode} (imp's CLI's exit code, or 255 from ssh)`;
  }

  return pickIdentityVerdict(check.stdout);
}

function pickIdentityVerdict(answer: string) {
  const identity = parseAnswer(answer);
  const kind = findJSONField(identity, 'kind');
  const name = findJSONField(identity, 'name');

  if (typeof kind !== 'string' || typeof name !== 'string') {
    return 'impd answered without an identity';
  }

  return kind === 'token' && name === 'atc-cloud' ? 'good' : 'bad';
}

function parseAnswer(answer: string): unknown {
  try {
    const value: unknown = JSON.parse(answer);

    return value;
  } catch {
    return undefined;
  }
}
