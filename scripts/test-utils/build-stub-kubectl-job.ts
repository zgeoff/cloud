import { readFileSync, statSync } from 'node:fs';
import { findJSONField } from '../find-json-field.ts';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

interface StubJobCondition {
  readonly type: string;
  readonly status: string;
  readonly reason?: string;
}

export interface StubKubectlJobOptions {
  // the name the Job's generateName gives it
  readonly jobName: string;

  // the Job's conditions at each get, in turn; the last stays once the list runs out
  readonly conditions: readonly (readonly StubJobCondition[])[];
  readonly logs: string;
  readonly configMaps?: readonly string[];
}

interface KubeconfigRead {
  readonly text: string;
  readonly mode: number;
}

export interface StubKubectlJob {
  readonly handler: StubHandler;
  readonly configMaps: ReadonlySet<string>;
  readonly createdObjects: readonly unknown[];

  // the file KUBECONFIG names, as each kubectl call found it
  readonly kubeconfigs: readonly KubeconfigRead[];
}

// kubectl 1.34's answers for the calls a Job run makes: delete --ignore-not-found prints nothing
// for a missing object, create prints `<kind>/<name> created` or with --output name only
// `<kind>/<name>`, and a create of a name that exists exits 1 with AlreadyExists
export function buildStubKubectlJob(options: Readonly<StubKubectlJobOptions>): StubKubectlJob {
  const configMaps = new Set(options.configMaps);

  const createdObjects: unknown[] = [];
  const kubeconfigs: KubeconfigRead[] = [];
  let gets = 0;

  const answer = (call: StubCall): StubAnswer | undefined => {
    const [command, verb, ...rest] = call.argv;

    if (command !== 'kubectl') {
      return undefined;
    }

    const kubeconfig = call.options.env?.['KUBECONFIG'];

    if (kubeconfig !== undefined) {
      kubeconfigs.push({
        text: readFileSync(kubeconfig, 'utf8'),
        mode: statSync(kubeconfig).mode % 0o1000,
      });
    }

    if (verb === 'delete' && rest[0] === 'configmap' && rest[1] !== undefined) {
      const isHeld = configMaps.delete(rest[1]);

      return { stdout: isHeld ? `configmap "${rest[1]}" deleted\n` : '' };
    }

    if (verb === 'create') {
      return createObject(call, configMaps, createdObjects, options.jobName);
    }

    if (verb === 'get' && rest.includes(`job.batch/${options.jobName}`)) {
      const conditions = options.conditions[Math.min(gets, options.conditions.length - 1)] ?? [];

      gets += 1;

      return { stdout: JSON.stringify({ kind: 'Job', status: { conditions } }) };
    }

    if (verb === 'logs' && rest.includes(`job.batch/${options.jobName}`)) {
      return { stdout: options.logs };
    }

    return undefined;
  };

  return { handler: answer, configMaps, createdObjects, kubeconfigs };
}

function createObject(
  call: StubCall,
  configMaps: Set<string>,
  createdObjects: unknown[],
  jobName: string,
): StubAnswer {
  const object: unknown = JSON.parse(call.stdin);

  createdObjects.push(object);

  const kind = findJSONField(object, 'kind');
  const name = findJSONField(findJSONField(object, 'metadata'), 'name');

  if (kind === 'ConfigMap' && typeof name === 'string') {
    if (configMaps.has(name)) {
      return {
        exitCode: 1,
        stderr: `Error from server (AlreadyExists): error when creating "STDIN": configmaps "${name}" already exists\n`,
      };
    }

    configMaps.add(name);

    return { stdout: `configmap/${name} created\n` };
  }

  return { stdout: `job.batch/${jobName}\n` };
}
