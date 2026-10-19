import type { Runner } from '../run-process.ts';

export interface BumpContext {
  readonly cwd: string;
  readonly run: Runner;
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

export interface BumpPR {
  readonly number: number;
  readonly url: string;
  readonly autoMerge: boolean;
  readonly labels: readonly string[];
  readonly head: string;
}

export interface BumpBranch {
  readonly name: string;
  readonly title: string;

  // the branch's head on origin before the push, or empty when it does not exist yet
  readonly lease: string;

  readonly same: boolean;

  // the branch already bumps to this release, which its commit's title names
  readonly sameRelease: boolean;
}
