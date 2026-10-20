import { expect, mock, test } from 'bun:test';
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
    'GitHub GET /repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 401: Bad credentials',
  );
});

test('#readComposeFile rejects with the bare status when GitHub fails with a body that is not JSON', () => {
  server.use(
    http.get(
      `${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml`,
      () => new HttpResponse('<html>Bad gateway</html>', { status: 502 }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub GET /repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 502',
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

test('#updateCommitStatus rejects with the bare status when the refusal body holds no message', () => {
  server.use(
    http.post(`${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`, () =>
      HttpResponse.json({ errors: [{ code: 'custom' }] }, { status: 422 }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.updateCommitStatus({
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      context: 'sdk-contract',
      state: 'success',
      description: '18 pass, 0 fail',
    }),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 422',
  );
});

test('#updateCommitStatus rejects with the status and the permission when the refusal body breaks off', () => {
  server.use(
    http.post(
      `${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`,
      () =>
        new HttpResponse(
          new ReadableStream({
            start: (controller) => {
              controller.error(new Error('connection reset'));
            },
          }),
          { status: 403, headers: { 'x-accepted-github-permissions': 'statuses=write' } },
        ),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.updateCommitStatus({
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      context: 'sdk-contract',
      state: 'success',
      description: '18 pass, 0 fail',
    }),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 403 (the token needs statuses=write)',
  );
});

test("#updateCommitStatus sends the service's token to the pull request's repository and head commit", async () => {
  const recordRequest = mock((request: Request) => ({
    url: request.url,
    authorization: request.headers.get('authorization'),
  }));

  server.use(
    http.post(`${githubAPIURL}/repos/:owner/:name/statuses/:sha`, (info) => {
      recordRequest(info.request);

      return HttpResponse.json({ state: 'pending', context: 'sdk-contract' }, { status: 201 });
    }),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updateCommitStatus({
    repo: 'acme/greenhouse',
    sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    context: 'sdk-contract',
    state: 'pending',
    description: 'Running the SDK contract suite',
  });

  expect(recordRequest.mock.results).toStrictEqual([
    {
      type: 'return',
      value: {
        url: `${githubAPIURL}/repos/acme/greenhouse/statuses/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`,
        authorization: 'Bearer ghp_stub-preview-token',
      },
    },
  ]);
});

test('#updateCommitStatus rejects with the permission GitHub names when the token cannot write statuses', () => {
  // GitHub's answer to a fine-grained token without Commit statuses write (docs.github.com/en/rest:
  // authentication/permissions-required-for-fine-grained-personal-access-tokens)
  server.use(
    http.post(`${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`, () =>
      HttpResponse.json(
        { message: 'Resource not accessible by personal access token', status: '403' },
        { status: 403, headers: { 'x-accepted-github-permissions': 'statuses=write' } },
      ),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  expect(
    client.updateCommitStatus({
      repo: 'acme/greenhouse',
      sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      context: 'sdk-contract',
      state: 'success',
      description: '18 pass, 0 fail',
    }),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 403: Resource not accessible by personal access token (the token needs statuses=write)',
  );
});
