// What the commit status says once a run of the SDK contract suite ends: the guest command's
// result, or null when the host's deadline passed first
interface ContractResult {
  // null when a signal ended the command
  readonly code: number | null;
  readonly output: string;
}

interface ContractStatus {
  readonly state: 'success' | 'failure';
  readonly description: string;
}

// coreutils' `timeout` exits 124 when its bound passes, and 137 when its kill after the bound ends
// the command
const timeoutCodes = new Set([124, 137]);

export function buildContractStatus(
  result: ContractResult | null,
  timeoutMs: number,
): ContractStatus {
  const limit = `${Math.round(timeoutMs / 60_000)} min`;

  if (result === null || (result.code !== null && timeoutCodes.has(result.code))) {
    return { state: 'failure', description: `The suite ran past its ${limit} limit` };
  }

  const summary = findTestSummary(result.output);

  if (result.code === 0) {
    return { state: 'success', description: summary ?? 'The suite passed' };
  }

  const exit = result.code === null ? 'on a signal' : `with ${result.code}`;

  return {
    state: 'failure',
    description: summary ?? `The run exited ${exit} before the suite reported`,
  };
}

// bun test ends with one line per outcome, such as ` 15 pass` and ` 3 fail`
function findTestSummary(output: string): string | null {
  const pass = /^\s*(?<count>\d+) pass$/mu.exec(output)?.groups?.['count'];
  const fail = /^\s*(?<count>\d+) fail$/mu.exec(output)?.groups?.['count'];

  if (pass === undefined || fail === undefined) {
    return null;
  }

  return `${pass} pass, ${fail} fail`;
}
