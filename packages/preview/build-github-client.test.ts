import { expect, mock, onTestFinished, test } from 'bun:test';
import { verify } from 'node:crypto';
import { HttpResponse, http } from 'msw';
import { buildGitHubClient, previewCommentMarker } from './build-github-client.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { stubApp, stubAppPublicKey } from './mocks/github-app.ts';
import {
  commitStatuses,
  composeFiles,
  installationTokens,
  issueComments,
  pullRequestFiles,
  uninstalledRepos,
} from './mocks/github-state.ts';
import { server } from './mocks/node.ts';

test('it mints a new installation token for each call, so no token outlives its call', async () => {
  composeFiles.set('acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'services: {}\n');

  const recordAuthorization = mock((authorization: string | null) => authorization);

  server.events.on('request:start', (event) => {
    recordAuthorization(event.request.headers.get('authorization'));
  });

  onTestFinished(() => {
    server.events.removeAllListeners('request:start');
  });

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  await client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  await client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');

  expect(installationTokens.map((token) => token.token)).toStrictEqual(['ghs_stub1', 'ghs_stub2']);

  expect(
    recordAuthorization.mock.calls
      .flat()
      .filter((authorization) => authorization?.startsWith('Bearer ghs_') === true),
  ).toStrictEqual(['Bearer ghs_stub1', 'Bearer ghs_stub2']);
});

test('it scopes each installation token to the one repository the call touches', async () => {
  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  await client.readPullRequestFiles('nursery/seedlings', 4);

  expect(installationTokens).toStrictEqual([
    { token: 'ghs_stub1', repos: ['nursery/seedlings'], expiresAt: expect.toBeValidDate() },
  ]);
});

test("it signs the App's JWT with its key, issued by its client ID from a minute before now to nine minutes after", async () => {
  const now = new Date(Math.floor(Date.now() / 1000) * 1000);

  const recordJWT = mock((authorization: string) => authorization);

  // an answer of nothing passes the request on to the stand-in's own handler
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/installation`, (info) => {
      recordJWT(info.request.headers.get('authorization') ?? '');
    }),
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => now);

  await client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');

  const [header = '', claims = '', signature = ''] =
    recordJWT.mock.calls.at(0)?.[0].slice('Bearer '.length).split('.') ?? [];

  expect(JSON.parse(Buffer.from(header, 'base64url').toString())).toStrictEqual({
    alg: 'RS256',
    typ: 'JWT',
  });

  expect(JSON.parse(Buffer.from(claims, 'base64url').toString())).toStrictEqual({
    iat: now.getTime() / 1000 - 60,
    exp: now.getTime() / 1000 + 540,
    iss: 'Iv23liStubPreviewApp',
  });

  expect(
    verify(
      'sha256',
      Buffer.from(`${header}.${claims}`),
      stubAppPublicKey,
      Buffer.from(signature, 'base64url'),
    ),
  ).toBeTrue();
});

test('it rejects an installation answer whose ID is not a number', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/installation`, () =>
      HttpResponse.json({ id: '7001', account: { login: 'acme' } }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: ['id'] }] });
});

test('it rejects an access token answer without a token', () => {
  server.use(
    http.post(`${githubAPIURL}/app/installations/:id/access_tokens`, () =>
      HttpResponse.json({}, { status: 201 }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: ['token'] }] });
});

test('it rejects a call to a repository the App is not installed on', () => {
  uninstalledRepos.add('acme/greenhouse');

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub GET /repos/acme/greenhouse/installation: HTTP 404: Not Found',
  );
});

test('#readComposeFile reads preview/compose.yaml at the commit', async () => {
  composeFiles.set(
    'acme/greenhouse@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'services:\n  web: {}\n',
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  const result = await client.readComposeFile(
    'acme/greenhouse',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  expect(result).toBe('services:\n  web: {}\n');
});

test('#readComposeFile returns null for a commit without the file', async () => {
  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toThrowWithMessage(
    Error,
    'GitHub GET /repos/acme/greenhouse/contents/preview/compose.yaml?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 502',
  );
});

test('#updatePreviewComment posts a comment that starts with the marker', async () => {
  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  await client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'first' });

  expect(issueComments).toStrictEqual([
    {
      id: expect.toBeNumber(),
      author: 'acme-previews[bot]',
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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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
      author: 'acme-previews[bot]',
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
      author: 'acme-previews[bot]',
      repo: 'acme/greenhouse',
      number: 17,
      body: `${previewCommentMarker}\nfirst`,
    },
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  const result = await client.readPullRequestFiles('acme/greenhouse', 17);

  expect(result).toHaveLength(101);
  expect(result.at(-1)).toStrictEqual({ path: 'bun.lock', patch: null });
});

test('#updateCommitStatus posts the state, the context and the description on the commit', async () => {
  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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
  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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
    'GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 403 (the App needs statuses=write)',
  );
});

test("#updateCommitStatus sends an installation token minted for the call to the pull request's repository and head commit", async () => {
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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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
        authorization: 'Bearer ghs_stub1',
      },
    },
  ]);
});

test('#updateCommitStatus rejects with the permission GitHub names when the App cannot write statuses', () => {
  // GitHub's answer to an App without Commit statuses write (docs.github.com/en/rest:
  // authentication/permissions-required-for-github-apps)
  server.use(
    http.post(`${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`, () =>
      HttpResponse.json(
        { message: 'Resource not accessible by integration', status: '403' },
        { status: 403, headers: { 'x-accepted-github-permissions': 'statuses=write' } },
      ),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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
    'GitHub POST /repos/acme/greenhouse/statuses/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: HTTP 403: Resource not accessible by integration (the App needs statuses=write)',
  );
});

// GitHub answers a rate limit with a 403 or a 429 that sets x-ratelimit-remaining to 0 or sends
// retry-after (docs.github.com/en/rest: using-the-rest-api/rate-limits-for-the-rest-api)
test.each([
  ['a 403 for a missing permission', 403, {}, true],
  ['a 404', 404, {}, true],
  ['a 422', 422, {}, true],
  ['a 408', 408, {}, false],
  ['a 429', 429, {}, false],
  ['a 403 with no rate limit left', 403, { 'x-ratelimit-remaining': '0' }, false],
  ['a 403 with retry-after', 403, { 'retry-after': '60' }, false],
  ['a 502', 502, {}, false],
])(
  '#updateCommitStatus rejects %s with its status and permanent set to %p',
  (_, status, headers, permanent) => {
    server.use(
      http.post(`${githubAPIURL}/repos/acme/greenhouse/statuses/:sha`, () =>
        HttpResponse.json({ message: 'Refused' }, { status, headers }),
      ),
    );

    const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

    expect(
      client.updateCommitStatus({
        repo: 'acme/greenhouse',
        sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        context: 'sdk-contract',
        state: 'success',
        description: '18 pass, 0 fail',
      }),
    ).rejects.toMatchObject({ name: 'GitHubRequestError', status, permanent });
  },
);

test('#readComposeFile rejects a contents answer whose content is not a string', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/contents/preview/compose.yaml`, () =>
      HttpResponse.json({ type: 'file', encoding: 'base64', content: 42 }),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(
    client.readComposeFile('acme/greenhouse', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: ['content'] }] });
});

test('#updatePreviewComment rejects an App answer without a slug', () => {
  server.use(http.get(`${githubAPIURL}/app`, () => HttpResponse.json({ name: 'Acme previews' })));

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(
    client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'first' }),
  ).rejects.toMatchObject({ name: 'ZodError', issues: [{ path: ['slug'] }] });
});

test('#updatePreviewComment rejects a comments page whose comment has no ID', () => {
  server.use(
    http.get(`${githubAPIURL}/repos/acme/greenhouse/issues/17/comments`, () =>
      HttpResponse.json([{ body: 'hello', user: { login: 'acme-previews[bot]' } }]),
    ),
  );

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

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

  const client = buildGitHubClient(githubAPIURL, stubApp, () => new Date());

  expect(client.readPullRequestFiles('acme/greenhouse', 17)).rejects.toMatchObject({
    name: 'ZodError',
    issues: [{ path: [0, 'filename'] }],
  });
});
