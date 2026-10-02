// External health check for geoff.cloud (#8). Monitoring on the host cannot report
// that the host is down, so this Worker probes from Cloudflare's edge on a cron.
//
// A probe of mcp.geoff.cloud tells three failures apart:
// - 530 or 1033: no tunnel connector, so cloudflared or the host is down
// - 502 or 504: the tunnel is up, but the PC or atc behind it is not
// - anything else: up (atc answers 401 or 404 to an unauthenticated probe)
//
// Each target's last state lives in R2; a change of state posts to ALERT_URL when
// that secret is set, and is always logged.

interface R2Object {
  text: () => Promise<string>;
}

interface R2Bucket {
  get: (key: string) => Promise<R2Object | null>;
  put: (key: string, value: string) => Promise<unknown>;
}

interface Env {
  readonly STATE: R2Bucket;
  readonly TARGETS: string;
  readonly ALERT_URL?: string;
}

interface Target {
  readonly name: string;
  readonly url: string;
}

type Health = 'up' | 'tunnel-down' | 'origin-down' | 'unreachable';

const probeTimeoutMs = 10_000;

const handler = {
  async scheduled(_controller: unknown, env: Env): Promise<void> {
    const targets = parseTargets(env.TARGETS);

    await Promise.all(targets.map((target) => checkTarget(target, env)));
  },
};

export default handler;

function parseTargets(raw: string): Target[] {
  const parsed: unknown = JSON.parse(raw);

  if (!Array.isArray(parsed) || !parsed.every((item) => isTarget(item))) {
    throw new Error('TARGETS must be a JSON array of { name, url }');
  }

  return parsed;
}

function isTarget(value: unknown): value is Target {
  return (
    typeof value === 'object' &&
    value !== null &&
    'name' in value &&
    typeof value.name === 'string' &&
    'url' in value &&
    typeof value.url === 'string'
  );
}

async function checkTarget(target: Target, env: Env): Promise<void> {
  const health = await readHealth(target.url);

  const key = `state:${target.name}`;

  const previous = await readStoredHealth(env.STATE, key);

  if (previous === health) {
    return;
  }

  await env.STATE.put(key, health);

  const message = `geoff.cloud: ${target.name} is ${health} (was ${previous ?? 'unknown'})`;

  console.log(message);

  if (env.ALERT_URL !== undefined && env.ALERT_URL !== '') {
    await sendAlert(env.ALERT_URL, message);
  }
}

async function readStoredHealth(bucket: R2Bucket, key: string): Promise<string | null> {
  const stored = await bucket.get(key);

  return stored === null ? null : stored.text();
}

async function readHealth(url: string): Promise<Health> {
  try {
    const response = await fetch(url, {
      redirect: 'manual',
      signal: AbortSignal.timeout(probeTimeoutMs),
    });

    return pickHealth(response.status);
  } catch {
    return 'unreachable';
  }
}

function pickHealth(status: number): Health {
  if (status === 530 || status === 1033) {
    return 'tunnel-down';
  }

  if (status === 502 || status === 504) {
    return 'origin-down';
  }

  return 'up';
}

// The body carries `content` (Discord), `text` (Slack) and `message`, so most
// webhook receivers show it without a per-service format.
async function sendAlert(url: string, message: string): Promise<void> {
  await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ content: message, text: message, message }),
  });
}
