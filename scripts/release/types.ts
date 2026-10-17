import type { Runner } from '../run-process.ts';

// The shared shapes of the release bump's pull request steps

// where a bump step runs: a zgeoff/cloud clone whose origin it pushes to, with a git identity and
// gh signed in
export interface BumpContext {
  readonly cwd: string;
  readonly run: Runner;
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

// this repository's own pull request for a bump's branch, as gh lists it
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

  // the branch already changes the same files to the same contents
  readonly same: boolean;

  // the branch already bumps to this release, which its commit's title names
  readonly sameRelease: boolean;
}
