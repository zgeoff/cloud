import { mkdirSync, readFileSync, statSync } from 'node:fs';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

export interface StubNixieCheckoutAnswers {
  readonly clone?: StubAnswer;
  readonly install?: StubAnswer;
  readonly attach?: StubAnswer;
  readonly doctor?: StubAnswer;
}

interface KubeconfigRead {
  readonly text: string;
  readonly mode: number;
}

export interface StubNixieCheckout {
  readonly handler: StubHandler;

  // the file NIXIE_PROD_KUBECONFIG names, as each doctor call found it
  readonly kubeconfigs: readonly KubeconfigRead[];
}

// Stands in for git and bun on a checkout of nixie: the clone makes its folder, as git does, and
// every other call passes with no output unless the answers name it. The verify CLI's calls are
// `bun run --silent verify <command> … --target prod`.
export function buildStubNixieCheckout(
  answers: Readonly<StubNixieCheckoutAnswers>,
): StubNixieCheckout {
  const kubeconfigs: KubeconfigRead[] = [];

  const answer = (call: StubCall): StubAnswer | undefined => {
    const [tool, ...args] = call.argv;

    if (tool === 'git' && args.includes('clone')) {
      mkdirSync(args.at(-1) ?? '', { recursive: true });

      return answers.clone ?? {};
    }

    if (tool === 'git' && args.includes('switch')) {
      return {};
    }

    if (tool === 'bun' && args[0] === 'install') {
      return answers.install ?? {};
    }

    if (tool !== 'bun' || args.slice(0, 3).join(' ') !== 'run --silent verify') {
      return undefined;
    }

    const kubeconfig = call.options.env?.['NIXIE_PROD_KUBECONFIG'] ?? '';

    if (args[3] === 'doctor') {
      kubeconfigs.push({
        text: readFileSync(kubeconfig, 'utf8'),
        mode: statSync(kubeconfig).mode % 0o1000,
      });

      return answers.doctor ?? {};
    }

    return args[3] === 'attach' ? (answers.attach ?? {}) : {};
  };

  return { handler: answer, kubeconfigs };
}
