import type { Runner } from '../run-process.ts';
import { buildNixieVerifyKubeconfig } from './build-nixie-verify-kubeconfig.ts';
import { parseTokenRequest } from './parse-token-request.ts';

export interface NixieVerifyKubeconfigRequest {
  // the path of a kubeconfig that may create the account's tokens
  readonly adminKubeconfig: string;

  // a Go duration, such as 10m or 2160h
  readonly duration: string;
}

export type NixieVerifyKubeconfig =
  | { readonly ok: true; readonly text: string; readonly token: string; readonly expiresAt: string }
  | { readonly ok: false; readonly error: string };

const kubectlTimeoutMs = 30_000;

// The jsonpath reads only the server and the CA, so none of the admin kubeconfig's credentials
// leave kubectl; --flatten turns a CA file into its data.
const clusterJSONPath = String.raw`jsonpath={.clusters[0].cluster.server}{"\n"}{.clusters[0].cluster.certificate-authority-data}`;

// Mints a token for the nixie-verify service account and returns a kubeconfig that holds it. The
// token comes back on kubectl's stdout and stays out of every argv.
export async function createNixieVerifyKubeconfig(
  run: Runner,
  request: Readonly<NixieVerifyKubeconfigRequest>,
): Promise<NixieVerifyKubeconfig> {
  const kubectl = ['kubectl', '--kubeconfig', request.adminKubeconfig];

  const viewed = await run(
    [...kubectl, 'config', 'view', '--minify', '--flatten', '--output', clusterJSONPath],
    { timeoutMs: kubectlTimeoutMs },
  );

  const [server = '', certificateAuthorityData = ''] = viewed.stdout.toString().split('\n');

  if (viewed.exitCode !== 0 || server === '' || certificateAuthorityData === '') {
    return {
      ok: false,
      error: `the admin kubeconfig names no server and CA (exit ${String(viewed.exitCode)}): ${viewed.stderr.toString().trim()}`,
    };
  }

  const created = await run(
    [
      ...kubectl,
      '--namespace',
      'nixie',
      'create',
      'token',
      'nixie-verify',
      `--duration=${request.duration}`,
      '--output',
      'json',
    ],
    { timeoutMs: kubectlTimeoutMs },
  );

  const minted = created.exitCode === 0 ? parseTokenRequest(created.stdout.toString()) : null;

  if (minted === null) {
    return {
      ok: false,
      error: `kubectl minted no token for nixie-verify (exit ${String(created.exitCode)}): ${created.stderr.toString().trim()}`,
    };
  }

  return {
    ok: true,
    text: buildNixieVerifyKubeconfig({ server, certificateAuthorityData }, minted.token),
    token: minted.token,
    expiresAt: minted.expiresAt,
  };
}
