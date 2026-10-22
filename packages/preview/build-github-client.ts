import type { KeyObject } from 'node:crypto';
import { sign } from 'node:crypto';
import { z } from 'zod';

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
const contentsFileSchema = z.object({ content: z.string().optional() });

export interface GitHubApp {
  readonly clientID: string;
  readonly privateKey: KeyObject;
}

type SendGitHubRequest = (request: GitHubRequest) => Promise<Response>;

export function buildGitHubClient(apiURL: string, app: GitHubApp, now: () => Date): GitHubClient {
  const sendAsApp: SendGitHubRequest = (request) =>
    sendGitHubRequest(apiURL, buildAppJWT(app, now()), request);

  // each call mints its own installation token, scoped to the one repository it touches, so the
  // service keeps no GitHub token past the call
  const createRepoSender = async (repo: string): Promise<SendGitHubRequest> => {
    const token = await createInstallationToken(sendAsApp, repo);

    return (request) => sendGitHubRequest(apiURL, token, request);
  };

  const appUser: { login?: string } = {};

  return {
    readComposeFile: async (repo, sha) => {
      const send = await createRepoSender(repo);

      const path = `/repos/${repo}/contents/preview/compose.yaml?ref=${encodeURIComponent(sha)}`;

      const response = await send({ path, allowMissing: true });

      if (response.status === 404) {
        return null;
      }

      const body = await response.json();

      const file = contentsFileSchema.parse(body);

      return Buffer.from(file.content ?? '', 'base64').toString('utf8');
    },
    updatePreviewComment: async (comment) => {
      appUser.login ??= await readAppLogin(sendAsApp);

      const send = await createRepoSender(comment.repo);
      const id = await readPreviewCommentID(send, comment, appUser.login);

      const body = JSON.stringify({ body: `${previewCommentMarker}\n${comment.body}` });

      await (id === null
        ? send({
            path: `/repos/${comment.repo}/issues/${comment.number}/comments`,
            method: 'POST',
            body,
          })
        : send({ path: `/repos/${comment.repo}/issues/comments/${id}`, method: 'PATCH', body }));
    },
    readPullRequestFiles: async (repo, number) => {
      const send = await createRepoSender(repo);

      return readPullRequestFiles(send, repo, number);
    },
    updateCommitStatus: async (status) => {
      const send = await createRepoSender(status.repo);

      await sendCommitStatus(send, status);
    },
  };
}

// GitHub refuses a JWT that expires more than 10 minutes ahead, and backdating the issue time
// covers a clock that runs ahead of GitHub's
// (docs.github.com/en/apps: generating-a-json-web-token-jwt-for-a-github-app)
function buildAppJWT(app: GitHubApp, now: Date): string {
  const issuedAt = Math.floor(now.getTime() / 1000) - 60;
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');

  const claims = Buffer.from(
    JSON.stringify({ iat: issuedAt, exp: issuedAt + 600, iss: app.clientID }),
  ).toString('base64url');

  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), app.privateKey);

  return `${header}.${claims}.${signature.toString('base64url')}`;
}

const installationSchema = z.object({ id: z.number() });
const accessTokenSchema = z.object({ token: z.string() });

async function createInstallationToken(
  sendAsApp: SendGitHubRequest,
  repo: string,
): Promise<string> {
  const lookup = await sendAsApp({ path: `/repos/${repo}/installation` });
  const lookupBody = await lookup.json();

  const installation = installationSchema.parse(lookupBody);
  const name = repo.split('/')[1] ?? '';

  const response = await sendAsApp({
    path: `/app/installations/${installation.id}/access_tokens`,
    method: 'POST',
    body: JSON.stringify({ repositories: [name] }),
  });

  const body = await response.json();

  return accessTokenSchema.parse(body).token;
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
    const refusal = await readGitHubRefusal(response);

    throw new Error(`GitHub ${method} ${request.path}: HTTP ${response.status}${refusal}`);
  }

  return response;
}

// GitHub's error body (docs.github.com/en/rest: using-the-rest-api/troubleshooting-the-rest-api)
const gitHubRefusalSchema = z.object({ message: z.string() });

async function readGitHubRefusal(response: Response): Promise<string> {
  // a connection that drops mid-body still leaves the status and the headers to report
  const text = await response.text().catch(() => '');

  const refusal = gitHubRefusalSchema.safeParse(parseGitHubBody(text));
  const message = refusal.success ? `: ${refusal.data.message}` : '';

  // GitHub names the permission an App lacks in this header, and the log is the only place an
  // operator reads it
  const permissions = response.headers.get('x-accepted-github-permissions');

  return permissions === null || permissions === ''
    ? message
    : `${message} (the App needs ${permissions})`;
}

// a proxy in front of GitHub can answer an error with HTML instead of GitHub's JSON
function parseGitHubBody(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

const commentUserSchema = z.object({ login: z.string() });

const issueCommentsSchema = z.array(
  z.object({ id: z.number(), body: z.string().optional(), user: commentUserSchema.nullish() }),
);

async function readPreviewCommentID(
  send: (request: GitHubRequest) => Promise<Response>,
  comment: PreviewComment,
  login: string,
): Promise<number | null> {
  for (let page = 1; ; page += 1) {
    const path = `/repos/${comment.repo}/issues/${comment.number}/comments?per_page=100&page=${page}`;

    const response = await send({ path });
    const body = await response.json();

    const comments = issueCommentsSchema.parse(body);

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

const appSchema = z.object({ slug: z.string() });

async function readAppLogin(sendAsApp: SendGitHubRequest): Promise<string> {
  const response = await sendAsApp({ path: '/app' });
  const body = await response.json();

  const app = appSchema.parse(body);

  // GitHub names an App's bot user after the App's slug
  return `${app.slug}[bot]`;
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

const pullRequestFileEntriesSchema = z.array(
  z.object({ filename: z.string(), patch: z.string().optional() }),
);

async function readPullRequestFiles(
  send: (request: GitHubRequest) => Promise<Response>,
  repo: string,
  number: number,
): Promise<PullRequestFile[]> {
  const files: PullRequestFile[] = [];

  for (let page = 1; ; page += 1) {
    const path = `/repos/${repo}/pulls/${number}/files?per_page=100&page=${page}`;

    const response = await send({ path });
    const body = await response.json();

    const entries = pullRequestFileEntriesSchema.parse(body);

    files.push(...entries.map((entry) => ({ path: entry.filename, patch: entry.patch ?? null })));

    if (entries.length < 100) {
      return files;
    }
  }
}
