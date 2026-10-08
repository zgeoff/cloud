// External health check for geoff.cloud (#8). Monitoring on the host cannot report
// that the host is down, so this Worker probes from Cloudflare's edge on a cron.
//
// A probe of a tunnel hostname tells three failures apart:
// - 530 or 1033: no tunnel connector, so cloudflared or the host is down
// - 502 or 504: the tunnel is up, but the atc gateway behind it is not
// - anything else: up (atc answers 401 or 404 to an unauthenticated probe)
//
// Each target's last state lives in R2; a change of state posts to ALERT_URL when
// that secret is set, and is always logged to the destination the handler is made with.
import type { R2Bucket } from '@cloudflare/workers-types';

// the R2 methods the check calls, typed by Cloudflare's runtime types
type StateBucket = Pick<R2Bucket, 'get' | 'put'>;

interface Env {
  readonly STATE: StateBucket;
  readonly TARGETS: string;
  readonly ALERT_URL?: string;
}

// where a change of state is logged; the console in production
interface LogDestination {
  readonly log: (message: string) => void;
}

type ScheduledHandler = (controller: unknown, env: Env) => Promise<void>;

export function makeScheduledHandler(destination: LogDestination): ScheduledHandler {
  return async (_controller, env) => {
    const targets = parseTargets(env.TARGETS);

    await Promise.all(targets.map((target) => checkTarget(target, env, destination)));
  };
}

interface Target {
  readonly name: string;
  readonly url: string;
}

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

async function checkTarget(target: Target, env: Env, destination: LogDestination): Promise<void> {
  const health = await readHealth(target.url);

  const key = `state:${target.name}`;

  const previous = await readStoredHealth(env.STATE, key);

  if (previous === health) {
    return;
  }

  await env.STATE.put(key, health);

  const message = `geoff.cloud: ${target.name} is ${health} (was ${previous ?? 'unknown'})`;

  destination.log(message);

  if (env.ALERT_URL !== undefined && env.ALERT_URL !== '') {
    await sendAlert(env.ALERT_URL, message);
  }
}

async function readStoredHealth(bucket: StateBucket, key: string): Promise<string | null> {
  const stored = await bucket.get(key);

  return stored === null ? null : stored.text();
}

type Health = 'up' | 'tunnel-down' | 'origin-down' | 'unreachable';

const probeTimeoutMs = 10_000;

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
