import { z } from 'zod';
import type { BoxxyRepos } from './types.ts';

// The boxxy server's spawn.repos, in a secret stack config key of its own, so a private repo's
// name stays out of the public Pulumi.prod.yaml, the preview and the ConfigMap's diff
export const boxxyReposKey = 'boxxySpawnRepos';
const name = z.string().min(1);

// a repo's git source, which atc clones on a target that gives each session a fresh machine; the
// broker adds the GitHub credential, so a URL that carries one is refused, as the server refuses it
const gitSourceURL = z
  .url()
  .refine(isURLWithoutCredential, 'a git source url must carry no credential');

const gitSource = z.strictObject({ url: gitSourceURL, ref: name });
const reposSchema = z.record(name, z.union([name, gitSource]));

// CI logs are public, so a refusal is one fixed sentence: a zod issue's path holds a repo's name,
// and its message can quote a key or a value of the secret
export function parseBoxxyRepos(text: string): BoxxyRepos {
  const result = reposSchema.safeParse(parseJSON(text));

  if (!result.success) {
    throw new Error(
      `stack config "${boxxyReposKey}" must map each repo to a folder or a git source { url, ref } whose url carries no credential`,
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
