import { expect, test } from 'bun:test';
import { githubAPIURL } from './github-api-url.ts';
import { commitStatuses, composeFiles, issueComments, pullRequestFiles } from './github-state.ts';

test('it serves a stored compose file base64-encoded, as GitHub contents API does', async () => {
  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
  );

  const result = await response.json();

  expect(result).toStrictEqual({
    type: 'file',
    encoding: 'base64',
    path: 'preview/compose.yaml',
    content: 'c2VydmljZXM6IHt9Cg==',
  });
});

test('it answers 404 for a compose file at a commit without one', async () => {
  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
  );

  expect(response.status).toBe(404);
});

test('it pages one pull request comments and leaves out other pull requests', async () => {
  issueComments.push(
    { id: 1, author: 'preview-bot', repo: 'acme/greenhouse', number: 17, body: 'one' },
    { id: 2, author: 'fern-reviewer', repo: 'acme/greenhouse', number: 18, body: 'elsewhere' },
    { id: 3, author: 'fern-reviewer', repo: 'acme/greenhouse', number: 17, body: 'two' },
  );

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/issues/17/comments?per_page=1&page=2`,
  );

  const result = await response.json();

  expect(result).toStrictEqual([{ id: 3, body: 'two', user: { login: 'fern-reviewer' } }]);
});

test("it answers the token's user", async () => {
  const response = await fetch(`${githubAPIURL}/user`);
  const result = await response.json();

  expect(result).toStrictEqual({ login: 'preview-bot', type: 'User' });
});

test('it stores a posted comment and answers 201', async () => {
  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/17/comments`, {
    method: 'POST',
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(201);

  expect(issueComments).toStrictEqual([
    { id: 9000, author: 'preview-bot', repo: 'acme/greenhouse', number: 17, body: 'hello' },
  ]);
});

test('it refuses a posted comment without a body with 422', async () => {
  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/17/comments`, {
    method: 'POST',
    body: JSON.stringify({ text: 'hello' }),
  });

  expect(response.status).toBe(422);
});

test('it refuses an edit without a body with 422', async () => {
  issueComments.push({
    id: 1,
    author: 'preview-bot',
    repo: 'acme/greenhouse',
    number: 17,
    body: 'a preview link',
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/1`, {
    method: 'PATCH',
    body: JSON.stringify({ text: 'hello' }),
  });

  expect(response.status).toBe(422);
});

test("it refuses an edit of another user's comment with 403", async () => {
  issueComments.push({
    id: 1,
    author: 'fern-reviewer',
    repo: 'acme/greenhouse',
    number: 17,
    body: 'a review note',
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/1`, {
    method: 'PATCH',
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(403);
});

test("it pages one pull request's changed files, as GitHub's files API does", async () => {
  pullRequestFiles.set('acme/greenhouse#17', [
    { filename: 'package.json', patch: '@@ -1 +1 @@\n-a\n+b' },
    { filename: 'bun.lock' },
  ]);

  pullRequestFiles.set('acme/greenhouse#18', [{ filename: 'README.md', patch: '@@' }]);

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/pulls/17/files?per_page=1&page=2`,
  );

  const result = await response.json();

  expect(result).toStrictEqual([{ filename: 'bun.lock' }]);
});

test('it lists no changed files for a pull request it holds none for', async () => {
  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/pulls/17/files`);
  const result = await response.json();

  expect(result).toStrictEqual([]);
});

test('it stores a posted commit status and answers 201', async () => {
  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    {
      method: 'POST',
      body: JSON.stringify({ state: 'pending', context: 'sdk-contract', description: 'Running' }),
    },
  );

  expect(response.status).toBe(201);

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'pending',
      context: 'sdk-contract',
      description: 'Running',
    },
  ]);
});

test('it refuses a commit status whose description runs past 140 characters with 422', async () => {
  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    {
      method: 'POST',
      body: JSON.stringify({
        state: 'failure',
        context: 'sdk-contract',
        description: 'x'.repeat(141),
      }),
    },
  );

  expect(response.status).toBe(422);
});

test('it refuses a commit status in a state GitHub does not define with 422', async () => {
  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    {
      method: 'POST',
      body: JSON.stringify({ state: 'passed', context: 'sdk-contract', description: 'Running' }),
    },
  );

  expect(response.status).toBe(422);
});

test('it answers 404 for an edit of a comment it does not hold', async () => {
  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/4242`, {
    method: 'PATCH',
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(404);
});
