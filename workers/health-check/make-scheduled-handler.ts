// Host monitoring cannot report the host down, so this Worker probes tunnel hostnames from the
// edge: 530/1033 reads tunnel down, 502/504 gateway down, else up.
import type { R2Bucket } from '@cloudflare/workers-types';
import { bindingNames } from './binding-names.ts';
import { targetsSchema } from './targets-schema.ts';
import type { Target } from './targets-schema.ts';

type StateBucket = Pick<R2Bucket, 'get' | 'put'>;

interface Env {
  readonly [bindingNames.state]: StateBucket;
  readonly [bindingNames.targets]: string;
  readonly [bindingNames.alertURL]?: string;
}

interface LogDestination {
  readonly log: (message: string) => void;
}

type ScheduledHandler = (controller: unknown, env: Env) => Promise<void>;

export function makeScheduledHandler(destination: LogDestination): ScheduledHandler {
  return async (_controller, env) => {
    const targets = parseTargets(env[bindingNames.targets]);

    await Promise.all(targets.map((target) => checkTarget(target, env, destination)));
  };
}

function parseTargets(raw: string): Target[] {
  const result = targetsSchema.safeParse(JSON.parse(raw));

  if (!result.success) {
    throw new Error(`${bindingNames.targets} must be a JSON array of { name, url }`);
  }

  return result.data;
}

async function checkTarget(target: Target, env: Env, destination: LogDestination): Promise<void> {
  const health = await readHealth(target.url);

  const key = `state:${target.name}`;

  const previous = await readStoredHealth(env[bindingNames.state], key);

  if (previous === health) {
    return;
  }

  await env[bindingNames.state].put(key, health);

  const message = `geoff.cloud: ${target.name} is ${health} (was ${previous ?? 'unknown'})`;

  destination.log(message);

  await sendAlert(env[bindingNames.alertURL], message);
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

async function sendAlert(url: string | undefined, message: string): Promise<void> {
  if (url === undefined || url === '') {
    return;
  }

  await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },

    // `content` for Discord, `text` for Slack and `message`, so most webhook receivers show it
    // without a per-service format
    body: JSON.stringify({ content: message, text: message, message }),
  });
}
