import { z } from 'zod';
import type { BoxxyRepos } from './types.ts';

// The boxxy server's spawn.repos, in a secret stack config key of its own, so a private repo's
// name stays out of the public Pulumi.prod.yaml, the preview and the ConfigMap's diff
export const boxxyReposKey = 'boxxySpawnRepos';
const name = z.string().min(1);

// a git source by the server's own rules (@boxxy/model's gitSourceSchema), so a value this passes
// never stops the server; a leading - would read as a git option
const gitSourceURL = z
  .url()
  .max(2048)
  .refine((url) => !url.startsWith('-'), 'a git source url must not start with -')
  .refine(isURLWithoutCredential, 'a git source url must carry no credential');

const gitSourceRef = z
  .string()
  .min(1)
  .max(255)
  .refine((ref) => !ref.startsWith('-'), 'a git source ref must not start with -');

// the NAME of the atc daemon's environment variable that holds the clone token, never the token;
// atc's own rule for the name, and the server's length cap
const credentialRef = z.strictObject({
  name: z
    .string()
    .max(255)
    .regex(/^[A-Za-z_]\w*$/u),
});

const gitSource = z.strictObject({
  url: gitSourceURL,
  ref: gitSourceRef,
  credentialRef: credentialRef.exactOptional(),
});

const reposSchema = z.record(name, z.union([name, gitSource]));

// CI logs are public, so a refusal is one fixed sentence: a zod issue's path holds a repo's name,
// and its message can quote a key or a value of the secret
export function parseBoxxyRepos(text: string): BoxxyRepos {
  const result = reposSchema.safeParse(parseJSON(text));

  if (!result.success) {
    throw new Error(
      `stack config "${boxxyReposKey}" must map each repo to a folder or a git source { url, ref, credentialRef? } whose url carries no credential`,
    );
  }

  return result.data;
}

// a URL that does not parse fails the url check already; new URL would throw an error that quotes it
function isURLWithoutCredential(url: string): boolean {
  if (!URL.canParse(url)) {
    return true;
  }

  const parsed = new URL(url);

  return parsed.username === '' && parsed.password === '';
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`stack config "${boxxyReposKey}" must hold JSON: an object of repos`);
  }
}
