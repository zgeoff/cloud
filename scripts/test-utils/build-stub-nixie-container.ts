import { mkdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

export interface StubNixieContainerAnswers {
  // the .bun-version the clone writes; unset, 1.4.4
  readonly bunVersion?: string;

  // when set, the clone makes .bun-version a symlink to this path in place of a file
  readonly bunVersionLinksTo?: string;

  // what `bun --version` in the container prints; unset, 1.4.4
  readonly imageBunVersion?: string;
  readonly clone?: StubAnswer;
  readonly build?: StubAnswer;
  readonly start?: StubAnswer;
  readonly install?: StubAnswer;
  readonly attach?: StubAnswer;
  readonly doctor?: StubAnswer;
  readonly detach?: StubAnswer;
  readonly remove?: StubAnswer;
}

interface KubeconfigRead {
  readonly text: string;
  readonly mode: number;
}

export interface StubNixieContainer {
  readonly handler: StubHandler;

  // the file the container sees at /kube/config, as each doctor call found it on the runner
  readonly kubeconfigs: readonly KubeconfigRead[];
}

// Stands in for git and docker: the clone makes its folder with a .bun-version, `docker run`'s
// `<folder>:/kube:ro` volume names the folder the doctor reads, and every other call passes with
// no output unless the answers name it.
export function buildStubNixieContainer(
  answers: Readonly<StubNixieContainerAnswers>,
): StubNixieContainer {
  const kubeconfigs: KubeconfigRead[] = [];
  let kubeconfigDirectory = '';

  const answerExec = (args: readonly string[]): StubAnswer | undefined => {
    if (args.join(' ') === 'bun --version') {
      return { stdout: `${answers.imageBunVersion ?? '1.4.4'}\n` };
    }

    if (args[1] === 'install') {
      return answers.install ?? {};
    }

    if (args.slice(0, 4).join(' ') !== 'bun run --silent verify') {
      return undefined;
    }

    if (args[4] === 'doctor') {
      const kubeconfig = join(kubeconfigDirectory, 'config');

      kubeconfigs.push({
        text: readFileSync(kubeconfig, 'utf8'),
        mode: statSync(kubeconfig).mode % 0o1000,
      });

      return answers.doctor ?? {};
    }

    return args[4] === 'attach' ? (answers.attach ?? {}) : (answers.detach ?? {});
  };

  const answer = (call: StubCall): StubAnswer | undefined => {
    const [tool, command, ...args] = call.argv;

    if (tool === 'git' && call.argv.includes('clone')) {
      return answerClone(call.argv.at(-1) ?? '', answers);
    }

    if (tool === 'git') {
      return {};
    }

    if (tool !== 'docker') {
      return undefined;
    }

    if (command === 'run') {
      const volume = args.find((arg) => arg.endsWith(':/kube:ro')) ?? '';

      kubeconfigDirectory = volume.slice(0, -':/kube:ro'.length);

      return answers.start ?? { stdout: 'a1b2c3\n' };
    }

    if (command === 'exec') {
      return answerExec(args.slice(1));
    }

    if (command === 'rm') {
      return answers.remove ?? {};
    }

    return command === 'build' ? (answers.build ?? {}) : {};
  };

  return { handler: answer, kubeconfigs };
}

function answerClone(checkout: string, answers: Readonly<StubNixieContainerAnswers>): StubAnswer {
  if (answers.clone?.exitCode !== undefined && answers.clone.exitCode !== 0) {
    return answers.clone;
  }

  mkdirSync(checkout, { recursive: true });

  if (answers.bunVersionLinksTo === undefined) {
    writeFileSync(join(checkout, '.bun-version'), `${answers.bunVersion ?? '1.4.4'}\n`);
  } else {
    symlinkSync(answers.bunVersionLinksTo, join(checkout, '.bun-version'));
  }

  return answers.clone ?? {};
}
