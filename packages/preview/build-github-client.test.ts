import { expect, test } from 'bun:test';
import { HttpResponse, http } from 'msw';
import { buildGitHubClient, previewCommentMarker } from './build-github-client.ts';
import { githubAPIURL } from './mocks/github-api-url.ts';
import { composeFiles, issueComments } from './mocks/github-state.ts';
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
      repo: 'acme/greenhouse',
      number: 17,
      body: `a review note ${index}`,
    })),
    { id: 101, repo: 'acme/greenhouse', number: 17, body: `${previewCommentMarker}\nfirst` },
  );

  const client = buildGitHubClient(githubAPIURL, 'ghp_stub-preview-token');

  await client.updatePreviewComment({ repo: 'acme/greenhouse', number: 17, body: 'second' });

  expect(issueComments).toBeArrayOfSize(101);

  expect(issueComments.find((comment) => comment.id === 101)?.body).toBe(
    `${previewCommentMarker}\nsecond`,
  );
});
