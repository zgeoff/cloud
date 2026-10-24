import type { NixieSandboxImagesPayload } from '@zgeoff/cloud-topology';
import {
  buildNixieSandboxImagesJob,
  nixieSandboxImagesConfigMap,
  nixieSandboxImagesScriptKey,
} from './build-nixie-sandbox-images-job.ts';
import type { NixieSandboxImagesJobInputs } from './build-nixie-sandbox-images-job.ts';

export function buildNixieSandboxImagesPayload(
  inputs: NixieSandboxImagesJobInputs,
): NixieSandboxImagesPayload {
  const job = buildNixieSandboxImagesJob(inputs);

  return {
    namespace: 'nixie',
    configMap: nixieSandboxImagesConfigMap,
    scriptKey: nixieSandboxImagesScriptKey,
    job: JSON.stringify(job),
  };
}
