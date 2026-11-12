import { expect, test } from 'bun:test';
import { parseBoxxyRepos } from './parse-boxxy-repos.ts';

test('it returns each repo as a folder or a git source', () => {
  const repos = {
    'owner/repo': '/workspace/repo',
    'owner/other': { url: 'https://github.com/owner/other', ref: 'main' },
  };

  expect(parseBoxxyRepos(JSON.stringify(repos))).toStrictEqual(repos);
});

test('it refuses a git source whose url carries a credential, and names no repo', () => {
  const repos = {
    'hidden-owner/hidden-repo': {
      url: 'https://user:fake-password@github.com/hidden-owner/hidden-repo',
      ref: 'main',
    },
  };

  expect(() => parseBoxxyRepos(JSON.stringify(repos))).toThrowWithMessage(
    Error,
    'stack config "boxxySpawnRepos" must map each repo to a folder or a git source { url, ref } whose url carries no credential',
  );
});

test('it refuses text that is not JSON, and leaves the text out', () => {
  expect(() => parseBoxxyRepos('hidden-owner/hidden-repo')).toThrowWithMessage(
    Error,
    'stack config "boxxySpawnRepos" must hold JSON: an object of repos',
  );
});

test('it refuses a repo with no folder or source, and names no repo', () => {
  const repos = { 'hidden-owner/hidden-repo': 7 };

  expect(() => parseBoxxyRepos(JSON.stringify(repos))).toThrowWithMessage(
    Error,
    'stack config "boxxySpawnRepos" must map each repo to a folder or a git source { url, ref } whose url carries no credential',
  );
});

test.each([
  [
    'a key it does not take',
    { url: 'https://github.com/owner/repo', ref: 'main', 'hidden-key': 1 },
  ],
  ['a url that does not parse', { url: 'https://[hidden-repo', ref: 'main' }],
])('it refuses a git source with %s, and quotes none of it', (_kind, source) => {
  const repos = { 'owner/repo': source };

  expect(() => parseBoxxyRepos(JSON.stringify(repos))).toThrowWithMessage(
    Error,
    'stack config "boxxySpawnRepos" must map each repo to a folder or a git source { url, ref } whose url carries no credential',
  );
});
