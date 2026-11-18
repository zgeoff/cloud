import { readFileSync } from 'node:fs';
import { constants } from 'node:os';

export interface ProcessStatus {
  readonly stopped: boolean;

  // the signals sent to the process that it has not taken yet, which a stopped process holds
  // until it continues
  readonly pendingSignals: readonly string[];
}

// Linux's /proc status is the one place a test can see that a signal reached a stopped process;
// it reads synchronously, so a condition wait can poll it
export function readProcessStatus(pid: number): ProcessStatus {
  const status = readFileSync(`/proc/${String(pid)}/status`, 'utf8');
  const state = /^State:\s*(?<state>\S)/mu.exec(status)?.groups?.['state'];
  const pending = /^ShdPnd:\s*(?<mask>[0-9a-f]+)$/mu.exec(status)?.groups?.['mask'] ?? '0';
  const mask = BigInt(`0x${pending}`);

  return {
    stopped: state === 'T',
    pendingSignals: Object.entries(constants.signals)
      .filter(([, number]) => (mask & (1n << BigInt(number - 1))) !== 0n)
      .map(([name]) => name),
  };
}
