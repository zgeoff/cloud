import { verify } from 'node:crypto';
import { HttpResponse, http } from 'msw';
import { z } from 'zod';
import { githubAPIURL } from './github-api-url.ts';
import {
  stubApp,
  stubAppLogin,
  stubAppPublicKey,
  stubAppSlug,
  stubInstallations,
} from './github-app.ts';
import {
  commitStatuses,
  composeFiles,
  installationTokens,
  issueComments,
  pullRequestFiles,
  uninstalledRepos,
} from './github-state.ts';

const commentRequestSchema = z.object({ body: z.string() });

// GitHub answers 422 for a state outside its four and a description past 140 characters
const commitStatusRequestSchema = z.object({
  state: z.enum(['error', 'failure', 'pending', 'success']),
  context: z.string().optional(),
  description: z.string().max(140).optional(),
});

const accessTokenRequestSchema = z.object({ repositories: z.array(z.string()).optional() });

// GitHub's REST endpoints that the service calls (docs.github.com/en/rest: apps/apps,
// repos/contents, issues/comments, pulls/pulls#list-pull-requests-files, commits/statuses), with
// GitHub's status codes, auth and the fields the service reads; a missing file or comment is a 404
export const handlers = [
  http.get(`${githubAPIURL}/app`, (info) =>
    isAppJWT(info.request)
      ? HttpResponse.json({ slug: stubAppSlug, client_id: stubApp.clientID })
      : buildJWTRefusedResponse(),
  ),
  http.get(`${githubAPIURL}/repos/:owner/:name/installation`, (info) => {
    if (!isAppJWT(info.request)) {
      return buildJWTRefusedResponse();
    }

    const owner = String(info.params['owner']);
    const repo = `${owner}/${String(info.params['name'])}`;
    const installation = [...stubInstallations].find(([, account]) => account === owner);

    return installation === undefined || uninstalledRepos.has(repo)
      ? buildNotFoundResponse()
      : HttpResponse.json({ id: installation[0], account: { login: owner } });
  }),
  http.post(`${githubAPIURL}/app/installations/:id/access_tokens`, async (info) => {
    if (!isAppJWT(info.request)) {
      return buildJWTRefusedResponse();
    }

    const account = stubInstallations.get(Number(info.params['id']));

    if (account === undefined) {
      return buildNotFoundResponse();
    }

    const body = await info.request.json();

    const payload = accessTokenRequestSchema.safeParse(body);

    if (!payload.success) {
      return buildValidationFailedResponse();
    }

    // without a list, the token reaches every repository of the installation
    const repos = (payload.data.repositories ?? ['*']).map((name) => `${account}/${name}`);

    if (repos.some((repo) => uninstalledRepos.has(repo))) {
      return HttpResponse.json(
        {
          message:
            'There is at least one repository that does not exist or is not accessible to the parent installation.',
          status: '422',
        },
        { status: 422 },
      );
    }

    const expiresAt = new Date(Date.now() + 3_600_000);

    const token = { token: `ghs_stub${installationTokens.length + 1}`, repos, expiresAt };

    installationTokens.push(token);

    return HttpResponse.json(
      {
        token: token.token,
        expires_at: expiresAt.toISOString(),
        repository_selection: 'selected',
      },
      { status: 201 },
    );
  }),
  http.get(`${githubAPIURL}/repos/:owner/:name/contents/preview/compose.yaml`, (info) => {
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;
    const refusal = findRepoTokenRefusal(info.request, repo);

    if (refusal !== null) {
      return refusal;
    }

    const ref = new URL(info.request.url).searchParams.get('ref');

    const file = composeFiles.get(`${repo}@${ref}`);

    return file === undefined
      ? buildNotFoundResponse()
      : HttpResponse.json({
          type: 'file',
          encoding: 'base64',
          path: 'preview/compose.yaml',
          content: Buffer.from(file).toString('base64'),
        });
  }),
  http.get(`${githubAPIURL}/repos/:owner/:name/issues/:number/comments`, (info) => {
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;
    const refusal = findRepoTokenRefusal(info.request, repo);

    if (refusal !== null) {
      return refusal;
    }

    const url = new URL(info.request.url);

    const perPage = Number(url.searchParams.get('per_page') ?? '30');
    const page = Number(url.searchParams.get('page') ?? '1');

    const comments = issueComments
      .filter(
        (comment) => comment.repo === repo && comment.number === Number(info.params['number']),
      )
      .slice((page - 1) * perPage, page * perPage)
      .map((comment) => ({ id: comment.id, body: comment.body, user: { login: comment.author } }));

    return HttpResponse.json(comments);
  }),
  http.post(`${githubAPIURL}/repos/:owner/:name/issues/:number/comments`, async (info) => {
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;
    const refusal = findRepoTokenRefusal(info.request, repo);

    if (refusal !== null) {
      return refusal;
    }

    const body = await info.request.json();

    const payload = commentRequestSchema.safeParse(body);

    if (!payload.success) {
      return buildValidationFailedResponse();
    }

    const comment = {
      id: 9000 + issueComments.length,
      author: stubAppLogin,
      repo,
      number: Number(info.params['number']),
      body: payload.data.body,
    };

    issueComments.push(comment);

    return HttpResponse.json({ id: comment.id, body: comment.body }, { status: 201 });
  }),
  http.patch(`${githubAPIURL}/repos/:owner/:name/issues/comments/:id`, async (info) => {
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;
    const refusal = findRepoTokenRefusal(info.request, repo);

    if (refusal !== null) {
      return refusal;
    }

    const body = await info.request.json();

    const payload = commentRequestSchema.safeParse(body);

    if (!payload.success) {
      return buildValidationFailedResponse();
    }

    const comment = issueComments.find(
      (candidate) => candidate.id === Number(info.params['id']) && candidate.repo === repo,
    );

    if (comment === undefined) {
      return buildNotFoundResponse();
    }

    // the App's bot edits only its own comments
    if (comment.author !== stubAppLogin) {
      return HttpResponse.json({ message: 'Forbidden', status: '403' }, { status: 403 });
    }

    comment.body = payload.data.body;

    return HttpResponse.json({ id: comment.id, body: comment.body });
  }),
  http.get(`${githubAPIURL}/repos/:owner/:name/pulls/:number/files`, (info) => {
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;
    const refusal = findRepoTokenRefusal(info.request, repo);

    if (refusal !== null) {
      return refusal;
    }

    const url = new URL(info.request.url);

    const perPage = Number(url.searchParams.get('per_page') ?? '30');
    const page = Number(url.searchParams.get('page') ?? '1');
    const key = `${repo}#${String(info.params['number'])}`;
    const files = (pullRequestFiles.get(key) ?? []).slice((page - 1) * perPage, page * perPage);

    return HttpResponse.json(files);
  }),
  http.post(`${githubAPIURL}/repos/:owner/:name/statuses/:sha`, async (info) => {
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;
    const refusal = findRepoTokenRefusal(info.request, repo);

    if (refusal !== null) {
      return refusal;
    }

    const body = await info.request.json();

    const parsed = commitStatusRequestSchema.safeParse(body);

    if (!parsed.success) {
      return buildValidationFailedResponse();
    }

    const payload = parsed.data;

    const status = {
      repo,
      sha: String(info.params['sha']),
      state: payload.state,
      context: payload.context ?? 'default',
      description: payload.description ?? '',
    };

    commitStatuses.push(status);

    return HttpResponse.json(
      { state: status.state, context: status.context, description: status.description },
      { status: 201 },
    );
  }),
];

const jwtHeaderSchema = z.object({ alg: z.literal('RS256') });
const jwtClaimsSchema = z.object({ iss: z.string(), iat: z.number(), exp: z.number() });

// GitHub takes an RS256 JWT signed with the App's key, issued by its client ID, issued no later
// than now and expiring within 10 minutes (docs.github.com/en/apps: generating-a-json-web-token-jwt-for-a-github-app)
function isAppJWT(request: Request): boolean {
  const parts = findBearerToken(request)?.split('.') ?? [];
  const [header, claims, signature] = parts;

  if (
    parts.length !== 3 ||
    header === undefined ||
    claims === undefined ||
    signature === undefined
  ) {
    return false;
  }

  const signed = verify(
    'sha256',
    Buffer.from(`${header}.${claims}`),
    stubAppPublicKey,
    Buffer.from(signature, 'base64url'),
  );

  const parsedHeader = jwtHeaderSchema.safeParse(parseBase64URLJSON(header));
  const parsedClaims = jwtClaimsSchema.safeParse(parseBase64URLJSON(claims));
  const nowSeconds = Date.now() / 1000;

  return (
    signed &&
    parsedHeader.success &&
    parsedClaims.success &&
    parsedClaims.data.iss === stubApp.clientID &&
    parsedClaims.data.iat <= nowSeconds &&
    parsedClaims.data.exp > nowSeconds &&
    parsedClaims.data.exp <= nowSeconds + 600
  );
}

function findBearerToken(request: Request): string | null {
  const header = request.headers.get('authorization');

  return header?.startsWith('Bearer ') === true ? header.slice('Bearer '.length) : null;
}

function parseBase64URLJSON(text: string): unknown {
  try {
    return JSON.parse(Buffer.from(text, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
}

function buildJWTRefusedResponse(): Response {
  return HttpResponse.json(
    { message: 'A JSON web token could not be decoded', status: '401' },
    { status: 401 },
  );
}

function buildNotFoundResponse(): Response {
  return HttpResponse.json({ message: 'Not Found', status: '404' }, { status: 404 });
}

function buildValidationFailedResponse(): Response {
  return HttpResponse.json({ message: 'Validation Failed', status: '422' }, { status: 422 });
}

// GitHub answers an unknown or expired token with 401, and hides a repository the token does not
// reach behind a 404
function findRepoTokenRefusal(request: Request, repo: string): Response | null {
  const bearer = findBearerToken(request);
  const token = installationTokens.find((candidate) => candidate.token === bearer);

  if (token === undefined || token.expiresAt.getTime() <= Date.now()) {
    return HttpResponse.json({ message: 'Bad credentials', status: '401' }, { status: 401 });
  }

  const owner = repo.split('/')[0] ?? '';

  return token.repos.includes(repo) || token.repos.includes(`${owner}/*`)
    ? null
    : buildNotFoundResponse();
}
