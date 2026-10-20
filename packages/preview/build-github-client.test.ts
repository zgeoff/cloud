import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { buildGitHubClient, previewCommentMarker } from './build-github-client.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import {
  commitStatuses,
  composeFiles,
  issueComments,
  pullRequestFiles,
} from './mocks/github-state.ts';
import { server } from './mocks/node.ts';

test('#readComposeFile reads preview/compose.yaml at the commit', async () => {
  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'services:\n  web: {}\n',
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  const result = await client.readComposeFile(
    'acme/greenhouse',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  expect(result).toBe('services:\n  web: {}\n');
});

test('#readComposeFile returns null for a commit without the file', async () => {
  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  const result = await client.readComposeFile(
    'acme/greenhouse',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  expect(result).toBeNull();
});

test('#readComposeFile rejects when GitHub fails', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml`, () =>
      HttpResponse.json({ message: 'Bad credentials' }, { status: 401 }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub GET /repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 401',
  );
});

test('#updatePreviewComment posts a comment that starts with the marker', async () => {
  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'first' });

  expect(issueComments).toStrictEqual([
    {
      id: expect.toBeNumber(),
      author: 'preview-bot',
      repo: 'acme/greenhouse',
      number: 17,
      body: `${previewCommentMarker}\nfirst`,
    },
  ]);
});

test("#updatePreviewComment posts its own comment when another user's comment carries the marker", async () => {
  issueComments.push({
    id: 1,
    author: 'fern-reviewer',
    repo: 'acme/greenhouse',
    number: 17,
    body: `${previewCommentMarker}\nquoted from the preview`,
  });

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'first' });

  expect(issueComments).toStrictEqual([
    {
      id: 1,
      author: 'fern-reviewer',
      repo: 'acme/greenhouse',
      number: 17,
      body: `${previewCommentMarker}\nquoted from the preview`,
    },
    {
      id: expect.toBeNumber(),
      author: 'preview-bot',
      repo: 'acme/greenhouse',
      number: 17,
      body: `${previewCommentMarker}\nfirst`,
    },
  ]);
});

test('#updatePreviewComment edits the marked comment past the first page of comments', async () => {
  issueComments.push(
    ...Array.from({ length: 100 }, (_, index) => ({
      id: index + 1,
      author: 'fern-reviewer',
      repo: 'acme/greenhouse',
      number: 17,
      body: `a review note ${index}`,
    })),
    {
      id: 101,
      author: 'preview-bot',
      repo: 'acme/greenhouse',
      number: 17,
      body: `${previewCommentMarker}\nfirst`,
    },
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'second' });

  expect(issueComments).toBeArrayOfSize(101);

  expect(issueComments.find((comment) => comment.id === 101)?.body).toBe(
    `${previewCommentMarker}\nsecond`,
  );
});

test('#readPullRequestFiles reads every changed file past the first page, with null for a diff GitHub left out', async () => {
  pullRequestFiles.set('acme/greenhouse#17', [
    ...Array.from({ length: 100 }, (_, index) => ({
      filename: `src/file-${index}.ts`,
      patch: '@@ -1 +1 @@',
    })),
    { filename: 'bun.lock' },
  ]);

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  const result = await client.readPullRequestFiles('acme/greenhouse', 17);

  expect(result).toHaveLength(101);
  expect(result.at(-1)).toStrictEqual({ path: 'bun.lock', patch: null });
});

test('#updateCommitStatus posts the state, the context and the description on the commit', async () => {
  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updateCommitStatus({
    repo: 'acme/greenhouse',
    sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    context: 'sdk-contract',
    state: 'success',
    description: '18 pass, 0 fail',
  });

  expect(commitStatuses).toStrictEqual([
    {
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      state: 'success',
      context: 'sdk-contract',
      description: '18 pass, 0 fail',
    },
  ]);
});

test('#updateCommitStatus cuts a description to the 140 characters GitHub accepts', async () => {
  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updateCommitStatus({
    repo: 'acme/greenhouse',
    sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    context: 'sdk-contract',
    state: 'failure',
    description: 'x'.repeat(200),
  });

  expect(commitStatuses.at(0)?.description).toBe('x'.repeat(140));
});

test('#readComposeFile rejects a contents answer whose content is not a string', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml`, () =>
      HttpResponse.json({ type: 'file', encoding: 'base64', content: 42 }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: ['content'] }] });
});

test('#updatePreviewComment rejects a token user answer without a login', () => {
  server.use(http.get(`${githubAPIURL}/user`, () => HttpResponse.json({ type: 'User' })));

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'first' }),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: ['login'] }] });
});

test('#updatePreviewComment rejects a comments page whose comment has no ID', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/issues/17/comments`, () =>
      HttpResponse.json([{ body: 'hello', user: { login: 'preview-bot' } }]),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'first' }),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: [0, 'id'] }] });
});

test('#readPullRequestFiles rejects a files page whose file has no filename', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/pulls/17/files`, () =>
      HttpResponse.json([{ patch: '@@ -1 +1 @@' }]),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(client.readPullRequestFiles('acme/greenhouse', 17)).rejects.toMatchObject({
    name: 'ZodError',
    issues: [{ path: [0, 'filename'] }],
  });
});
