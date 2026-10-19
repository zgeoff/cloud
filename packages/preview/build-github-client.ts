export interface GitHubClient {
  readonly readComposeFile: (repo: string, sha: string) => Promise<string | null>;

  readonly updatePreviewComment: (comment: PreviewComment) => Promise<void>;

  // GitHub leaves the diff out of a file whose diff is too large to show
  readonly readPullRequestFiles: (repo: string, number: number) => Promise<PullRequestFile[]>;

  readonly updateCommitStatus: (status: CommitStatus) => Promise<void>;
}

export interface PullRequestFile {
  readonly path: string;
  readonly patch: string | null;
}

interface CommitStatus {
  readonly repo: string;
  readonly sha: string;
  readonly context: string;
  readonly state: 'pending' | 'success' | 'failure' | 'error';
  readonly description: string;
}

interface PreviewComment {
  readonly repo: string;
  readonly number: number;
  readonly body: string;
}

export const previewCommentMarker = '<!-- cloud-preview -->';

export function buildGitHubClient(apiURL: string, token: string): GitHubClient {
  const send = (request: GitHubRequest): Promise<Response> =>
    sendGitHubRequest(apiURL, token, request);

  const tokenUser: { login?: string } = {};

  return {
    readComposeFile: async (repo, sha) => {
      const path = `/repos/${repo}/contents/preview/compose.yaml?ref=${encodeURIComponent(sha)}`;

      const response = await send({ path, allowMissing: true });

      if (response.status === 404) {
        return null;
      }

      // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- GitHub's contents API shape
      const file = (await response.json()) as { readonly content?: string };

      return Buffer.from(file.content ?? '', 'base64').toString('utf8');
    },
    updatePreviewComment: async (comment) => {
      tokenUser.login ??= await readTokenLogin(send);

      const id = await findPreviewCommentID(send, comment, tokenUser.login);

      const body = JSON.stringify({ body: `${previewCommentMarker}\n${comment.body}` });

      await (id === null
        ? send({
            path: `/repos/${comment.repo}/issues/${comment.number}/comments`,
            method: 'POST',
            body,
          })
        : send({ path: `/repos/${comment.repo}/issues/comments/${id}`, method: 'PATCH', body }));
    },
    readPullRequestFiles: (repo, number) => readPullRequestFiles(send, repo, number),
    updateCommitStatus: (status) => sendCommitStatus(send, status),
  };
}

interface GitHubRequest {
  readonly path: string;
  readonly method?: 'GET' | 'POST' | 'PATCH';
  readonly body?: string;

  // a 404 is an answer, not an error, where the caller reads it as a missing file
  readonly allowMissing?: boolean;
}

async function sendGitHubRequest(
  apiURL: string,
  token: string,
  request: GitHubRequest,
): Promise<Response> {
  const method = request.method ?? 'GET';
  const contentType = request.body === undefined ? {} : { 'content-type': 'application/json' };

  const response = await fetch(`${apiURL}${request.path}`, {
    method,
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${token}`,
      'x-github-api-version': '2022-11-28',
      ...contentType,
    },
    ...(request.body === undefined ? {} : { body: request.body }),
  });

  if (!response.ok && !(request.allowMissing === true && response.status === 404)) {
    throw new Error(`GitHub ${method} ${request.path}: HTTP ${response.status}`);
  }

  return response;
}

interface IssueComment {
  readonly id: number;
  readonly body?: string;
  readonly user?: { readonly login: string } | null;
}

async function findPreviewCommentID(
  send: (request: GitHubRequest) => Promise<Response>,
  comment: PreviewComment,
  login: string,
): Promise<number | null> {
  for (let page = 1; ; page += 1) {
    const path = `/repos/${comment.repo}/issues/${comment.number}/comments?per_page=100&page=${page}`;

    const response = await send({ path });

    // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- the same page, in GitHub's issue comments shape
    const comments = (await response.json()) as readonly IssueComment[];

    // anyone can paste the marker, and GitHub lets the service edit only its own comments
    const match = comments.find(
      (candidate) =>
        candidate.user?.login === login && candidate.body?.includes(previewCommentMarker) === true,
    );

    if (match !== undefined || comments.length < 100) {
      return match?.id ?? null;
    }
  }
}

async function readTokenLogin(
  send: (request: GitHubRequest) => Promise<Response>,
): Promise<string> {
  const response = await send({ path: '/user' });

  // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- GitHub's authenticated user shape
  const user = (await response.json()) as { readonly login: string };

  return user.login;
}

async function sendCommitStatus(
  send: (request: GitHubRequest) => Promise<Response>,
  status: CommitStatus,
): Promise<void> {
  // GitHub refuses a status whose description runs past 140 characters
  const description = status.description.slice(0, 140);

  await send({
    path: `/repos/${status.repo}/statuses/${status.sha}`,
    method: 'POST',
    body: JSON.stringify({ state: status.state, context: status.context, description }),
  });
}

interface PullRequestFileEntry {
  readonly filename: string;
  readonly patch?: string;
}

async function readPullRequestFiles(
  send: (request: GitHubRequest) => Promise<Response>,
  repo: string,
  number: number,
): Promise<PullRequestFile[]> {
  const files: PullRequestFile[] = [];

  for (let page = 1; ; page += 1) {
    const path = `/repos/${repo}/pulls/${number}/files?per_page=100&page=${page}`;

    const response = await send({ path });

    // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- the same page, in GitHub's pull request files shape
    const entries = (await response.json()) as readonly PullRequestFileEntry[];

    files.push(...entries.map((entry) => ({ path: entry.filename, patch: entry.patch ?? null })));

    if (entries.length < 100) {
      return files;
    }
  }
}
