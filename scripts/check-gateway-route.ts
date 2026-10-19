import type { ReadinessLine } from './format-readiness-line.ts';
import type { Runner } from './run-process.ts';

export async function checkGatewayRoute(run: Runner): Promise<ReadinessLine> {
  const lookup = await run(['getent', 'hosts', 'atc.geoff.cloud'], { timeoutMs: 30_000 });

  if (lookup.exitCode !== 0) {
    return { status: 'missing', text: 'DNS record atc.geoff.cloud' };
  }

  const code = await readMetadataStatus();

  return {
    status: code === '200' ? 'ok' : 'FAIL',
    text: `atc.geoff.cloud protected-resource metadata: ${code}`,
  };
}

async function readMetadataStatus() {
  try {
    const response = await fetch(
      'https://atc.geoff.cloud/.well-known/oauth-protected-resource/mcp',
      {
        redirect: 'manual',
        signal: AbortSignal.timeout(10_000),
      },
    );

    return String(response.status);
  } catch {
    return '000';
  }
}
