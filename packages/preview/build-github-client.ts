// The GitHub REST calls the service makes, as the token's owner
export interface GitHubClient {
  // preview/compose.yaml at a commit, or null when the commit has none and so has not opted in
  readonly readComposeFile: (repo: string, sha: string) => Promise<string | null>;

  // posts the pull request's preview comment, or edits it in place once one exists
  readonly updatePreviewComment: (comment: PreviewComment) => Promise<void>;
}

interface PreviewComment {
  readonly repo: string;
  readonly number: number;
  readonly body: string;
}

// The marker that tells the service's own comment from every other comment on the pull request
export const previewCommentMarker = '<!-- cloud-preview -->';

export function buildGitHubClient(apiURL: string, token: string): GitHubClient {
  const send = (request: GitHubRequest): Promise<Response> =>
    sendGitHubRequest(apiURL, token, request);

  return {
    readComposeFile: async (repo, sha) => {
      const path = `/repos/${repo}/contents/preview/compose.yaml?ref=${encodeURIComponent(sha)}`;

      const response = await send({ path, allowMissing: true });

      if (response.status === 404) {
        return null;
      }

      const file = (await response.json()) as { readonly content?: string };

      return Buffer.from(file.content ?? '', 'base64').toString('utf8');
    },
    updatePreviewComment: async (comment) => {
      const id = await findPreviewCommentID(send, comment);

      const body = JSON.stringify({ body: `${previewCommentMarker}\n${comment.body}` });

      await (id === null
        ? send({
            path: `/repos/${comment.repo}/issues/${comment.number}/comments`,
            method: 'POST',
            body,
          })
        : send({ path: `/repos/${comment.repo}/issues/comments/${id}`, method: 'PATCH', body }));
    },
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
}

// pages through the pull request's comments, a hundred at a time, until one holds the marker
async function findPreviewCommentID(
  send: (request: GitHubRequest) => Promise<Response>,
  comment: PreviewComment,
): Promise<number | null> {
  for (let page = 1; ; page += 1) {
    const path = `/repos/${comment.repo}/issues/${comment.number}/comments?per_page=100&page=${page}`;

    // oxlint-disable-next-line no-await-in-loop -- each page follows the one before it
    const response = await send({ path });

    // oxlint-disable-next-line no-await-in-loop -- the same page's body
    const comments = (await response.json()) as readonly IssueComment[];
    const match = comments.find((candidate) => candidate.body?.includes(previewCommentMarker));

    if (match !== undefined || comments.length < 100) {
      return match?.id ?? null;
    }
  }
}
