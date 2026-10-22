import { expect, test } from 'bun:test';
import { generateKeyPairSync, sign } from 'node:crypto';
import { githubAPIURL } from './github-api-url.ts';
import { stubApp } from './github-app.ts';
import {
  commitStatuses,
  composeFiles,
  installationTokens,
  issueComments,
  pullRequestFiles,
  uninstalledRepos,
} from './github-state.ts';

test('it answers the App with its slug for a JWT signed with its key', async () => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/app`, {
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
  });

  const result = await response.json();

  expect(result).toStrictEqual({ slug: 'acme-previews', client_id: 'Iv23liStubPreviewApp' });
});

test('it refuses a JWT signed with another key with 401', async () => {
  const otherKey = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), otherKey);

  const response = await fetch(`${githubAPIURL}/app`, {
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
  });

  expect(response.status).toBe(401);
});

test('it refuses an expired JWT with 401', async () => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 700, exp: nowSeconds - 100, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/app`, {
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
  });

  expect(response.status).toBe(401);
});

test('it refuses a JWT that expires more than 10 minutes ahead with 401', async () => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 3600, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/app`, {
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
  });

  expect(response.status).toBe(401);
});

test("it answers a repository's installation on its account", async () => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/repos/nursery/seedlings/installation`, {
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
  });

  const result = await response.json();

  expect(result).toStrictEqual({ id: 7002, account: { login: 'nursery' } });
});

test('it answers 404 for the installation of a repository the App is not installed on', async () => {
  uninstalledRepos.add('acme/greenhouse');

  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/installation`, {
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
  });

  expect(response.status).toBe(404);
});

test('it mints an installation token scoped to the named repositories', async () => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/app/installations/7001/access_tokens`, {
    method: 'POST',
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
    body: JSON.stringify({ repositories: ['greenhouse'] }),
  });

  expect(response.status).toBe(201);

  expect(installationTokens).toStrictEqual([
    { token: 'ghs_stub1', repos: ['acme/greenhouse'], expiresAt: expect.toBeValidDate() },
  ]);
});

test('it refuses a token for a repository the App is not installed on with 422', async () => {
  uninstalledRepos.add('acme/orchard');

  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = Buffer.from('{"alg":"RS256","typ":"JWT"}').toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: 'Iv23liStubPreviewApp' }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), stubApp.privateKey);

  const response = await fetch(`${githubAPIURL}/app/installations/7001/access_tokens`, {
    method: 'POST',
    headers: { authorization: `Bearer ${header}.${claims}.${signature.toString('base64url')}` },
    body: JSON.stringify({ repositories: ['orchard'] }),
  });

  expect(response.status).toBe(422);
});

test('it refuses a repository call without an installation token with 401', async () => {
  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
  );

  expect(response.status).toBe(401);
});

test.each([
  ['an empty authorization header', '', 3_600_000],
  ['a token without the Bearer scheme', 'ghs_greenhouse', 3_600_000],
  ['a token the stand-in never minted', 'Bearer ghs_unknown', 3_600_000],
  ['an expired token', 'Bearer ghs_greenhouse', -1000],
  ['a token that expires this instant', 'Bearer ghs_greenhouse', 0],
])('it refuses a repository call with %s with 401', async (_label, authorization, expiresInMs) => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + expiresInMs),
  });

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    { headers: { authorization } },
  );

  expect(response.status).toBe(401);
});

test('it hides a repository that the installation token does not reach behind a 404', async () => {
  installationTokens.push({
    token: 'ghs_orchard',
    repos: ['acme/orchard'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    { headers: { authorization: 'Bearer ghs_orchard' } },
  );

  expect(response.status).toBe(404);
});

test('it serves a stored compose file base64-encoded, as GitHub contents API does', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    { headers: { authorization: 'Bearer ghs_greenhouse' } },
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
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    { headers: { authorization: 'Bearer ghs_greenhouse' } },
  );

  expect(response.status).toBe(404);
});

test('it pages one pull request comments and leaves out other pull requests', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  issueComments.push(
    { id: 1, author: 'acme-previews[bot]', repo: 'acme/greenhouse', number: 17, body: 'one' },
    { id: 2, author: 'fern-reviewer', repo: 'acme/greenhouse', number: 18, body: 'elsewhere' },
    { id: 3, author: 'fern-reviewer', repo: 'acme/greenhouse', number: 17, body: 'two' },
  );

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/issues/17/comments?per_page=1&page=2`,
    { headers: { authorization: 'Bearer ghs_greenhouse' } },
  );

  const result = await response.json();

  expect(result).toStrictEqual([{ id: 3, body: 'two', user: { login: 'fern-reviewer' } }]);
});

test("it stores a posted comment as the App's bot and answers 201", async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/17/comments`, {
    method: 'POST',
    headers: { authorization: 'Bearer ghs_greenhouse' },
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(201);

  expect(issueComments).toStrictEqual([
    { id: 9000, author: 'acme-previews[bot]', repo: 'acme/greenhouse', number: 17, body: 'hello' },
  ]);
});

test('it refuses a posted comment without a body with 422', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/17/comments`, {
    method: 'POST',
    headers: { authorization: 'Bearer ghs_greenhouse' },
    body: JSON.stringify({ text: 'hello' }),
  });

  expect(response.status).toBe(422);
});

test('it refuses an edit without a body with 422', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  issueComments.push({
    id: 1,
    author: 'acme-previews[bot]',
    repo: 'acme/greenhouse',
    number: 17,
    body: 'a preview link',
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/1`, {
    method: 'PATCH',
    headers: { authorization: 'Bearer ghs_greenhouse' },
    body: JSON.stringify({ text: 'hello' }),
  });

  expect(response.status).toBe(422);
});

test("it edits the App's bot's own comment", async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  issueComments.push({
    id: 1,
    author: 'acme-previews[bot]',
    repo: 'acme/greenhouse',
    number: 17,
    body: 'a preview link',
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/1`, {
    method: 'PATCH',
    headers: { authorization: 'Bearer ghs_greenhouse' },
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(200);
  expect(issueComments.at(0)?.body).toBe('hello');
});

test.each([
  ['another user', 'fern-reviewer'],
  ['an empty login', ''],
  ['a case variant of the bot', 'Acme-Previews[bot]'],
  ['an upper-case variant of the bot', 'ACME-PREVIEWS[BOT]'],
  ['the slug without the bot suffix', 'acme-previews'],
  ['another bot with the same slug stem', 'acme-previews-staging[bot]'],
  ['the bot with a suffix after it', 'acme-previews[bot]x'],
])('it refuses an edit of a comment by %s with 403', async (_label, author) => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  issueComments.push({
    id: 1,
    author,
    repo: 'acme/greenhouse',
    number: 17,
    body: 'a review note',
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/1`, {
    method: 'PATCH',
    headers: { authorization: 'Bearer ghs_greenhouse' },
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(403);
});

test("it pages one pull request's changed files, as GitHub's files API does", async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  pullRequestFiles.set('acme/greenhouse#17', [
    { filename: 'package.json', patch: '@@ -1 +1 @@\n-a\n+b' },
    { filename: 'bun.lock' },
  ]);

  pullRequestFiles.set('acme/greenhouse#18', [{ filename: 'README.md', patch: '@@' }]);

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/pulls/17/files?per_page=1&page=2`,
    { headers: { authorization: 'Bearer ghs_greenhouse' } },
  );

  const result = await response.json();

  expect(result).toStrictEqual([{ filename: 'bun.lock' }]);
});

test('it lists no changed files for a pull request it holds none for', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/pulls/17/files`, {
    headers: { authorization: 'Bearer ghs_greenhouse' },
  });

  const result = await response.json();

  expect(result).toStrictEqual([]);
});

test('it stores a posted commit status and answers 201', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    {
      method: 'POST',
      headers: { authorization: 'Bearer ghs_greenhouse' },
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
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    {
      method: 'POST',
      headers: { authorization: 'Bearer ghs_greenhouse' },
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
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(
    `${githubAPIURL}/repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
    {
      method: 'POST',
      headers: { authorization: 'Bearer ghs_greenhouse' },
      body: JSON.stringify({ state: 'passed', context: 'sdk-contract', description: 'Running' }),
    },
  );

  expect(response.status).toBe(422);
});

test('it answers 404 for an edit of a comment it does not hold', async () => {
  installationTokens.push({
    token: 'ghs_greenhouse',
    repos: ['acme/greenhouse'],
    expiresAt: new Date(Date.now() + 3_600_000),
  });

  const response = await fetch(`${githubAPIURL}/repos/acme/greenhouse/issues/comments/4242`, {
    method: 'PATCH',
    headers: { authorization: 'Bearer ghs_greenhouse' },
    body: JSON.stringify({ body: 'hello' }),
  });

  expect(response.status).toBe(404);
});
