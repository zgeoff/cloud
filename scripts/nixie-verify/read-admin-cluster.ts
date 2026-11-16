import type { Runner } from '../run-process.ts';

export type AdminCluster =
  | { readonly ok: true; readonly server: string; readonly certificateAuthorityData: string }
  | { readonly ok: false; readonly error: string };

const kubectlTimeoutMs = 30_000;

// The jsonpath reads only the server and the CA, so none of the admin kubeconfig's credentials
// leave kubectl; --flatten turns a CA file into its data.
const clusterJSONPath = String.raw`jsonpath={.clusters[0].cluster.server}{"\n"}{.clusters[0].cluster.certificate-authority-data}`;

// Reads the API server's URL and CA from an admin kubeconfig.
export async function readAdminCluster(
  run: Runner,
  adminKubeconfig: string,
): Promise<AdminCluster> {
  const viewed = await run(
    [
      'kubectl',
      '--kubeconfig',
      adminKubeconfig,
      'config',
      'view',
      '--minify',
      '--flatten',
      '--output',
      clusterJSONPath,
    ],
    { timeoutMs: kubectlTimeoutMs },
  );

  const [server = '', certificateAuthorityData = ''] = viewed.stdout.toString().split('\n');

  if (viewed.exitCode !== 0 || server === '' || certificateAuthorityData === '') {
    return {
      ok: false,
      error: `the admin kubeconfig names no server and CA (exit ${String(viewed.exitCode)}): ${viewed.stderr.toString().trim()}`,
    };
  }

  return { ok: true, server, certificateAuthorityData };
}
