import { HttpResponse, http } from 'msw';
import { z } from 'zod';
import { githubAPIURL } from './github-api-url.ts';
import {
  commitStatuses,
  composeFiles,
  issueComments,
  pullRequestFiles,
  tokenLogin,
} from './github-state.ts';

const commentRequestSchema = z.object({ body: z.string() });

// GitHub answers 422 for a state outside its four and a description past 140 characters
const commitStatusRequestSchema = z.object({
  state: z.enum(['error', 'failure', 'pending', 'success']),
  context: z.string().optional(),
  description: z.string().max(140).optional(),
});

// GitHub's REST endpoints that the service calls (docs.github.com/en/rest: repos/contents,
// issues/comments, users/users, pulls/pulls#list-pull-requests-files, commits/statuses), with
// GitHub's status codes and the fields the service reads; a missing file or comment is a 404
export const handlers = [
  http.get(`${githubAPIURL}/user`, () => HttpResponse.json({ login: tokenLogin, type: 'User' })),
  http.get(`${githubAPIURL}/repos/:owner/:name/contents/preview/compose.yaml`, (info) => {
    const ref = new URL(info.request.url).searchParams.get('ref');

    const file = composeFiles.get(
      `${String(info.params['owner'])}/${String(info.params['name'])}@${ref}`,
    );

    return file === undefined
      ? HttpResponse.json({ message: 'Not Found', status: '404' }, { status: 404 })
      : HttpResponse.json({
          type: 'file',
          encoding: 'base64',
          path: 'preview/compose.yaml',
          content: Buffer.from(file).toString('base64'),
        });
  }),
  http.get(`${githubAPIURL}/repos/:owner/:name/issues/:number/comments`, (info) => {
    const url = new URL(info.request.url);

    const perPage = Number(url.searchParams.get('per_page') ?? '30');
    const page = Number(url.searchParams.get('page') ?? '1');
    const repo = `${String(info.params['owner'])}/${String(info.params['name'])}`;

    const comments = issueComments
      .filter(
        (comment) => comment.repo === repo && comment.number === Number(info.params['number']),
      )
      .slice((page - 1) * perPage, page * perPage)
      .map((comment) => ({ id: comment.id, body: comment.body, user: { login: comment.author } }));

    return HttpResponse.json(comments);
  }),
  http.post(`${githubAPIURL}/repos/:owner/:name/issues/:number/comments`, async (info) => {
    const body = await info.request.json();

    const payload = commentRequestSchema.safeParse(body);

    if (!payload.success) {
      return buildValidationFailedResponse();
    }

    const comment = {
      id: 9000 + issueComments.length,
      author: tokenLogin,
      repo: `${String(info.params['owner'])}/${String(info.params['name'])}`,
      number: Number(info.params['number']),
      body: payload.data.body,
    };

    issueComments.push(comment);

    return HttpResponse.json({ id: comment.id, body: comment.body }, { status: 201 });
  }),
  http.patch(`${githubAPIURL}/repos/:owner/:name/issues/comments/:id`, async (info) => {
    const body = await info.request.json();

    const payload = commentRequestSchema.safeParse(body);

    if (!payload.success) {
      return buildValidationFailedResponse();
    }

    const comment = issueComments.find((candidate) => candidate.id === Number(info.params['id']));

    if (comment === undefined) {
      return HttpResponse.json({ message: 'Not Found', status: '404' }, { status: 404 });
    }

    // the stand-in's token edits only its own comments
    if (comment.author !== tokenLogin) {
      return HttpResponse.json({ message: 'Forbidden', status: '403' }, { status: 403 });
    }

    comment.body = payload.data.body;

    return HttpResponse.json({ id: comment.id, body: comment.body });
  }),
  http.get(`${githubAPIURL}/repos/:owner/:name/pulls/:number/files`, (info) => {
    const url = new URL(info.request.url);

    const perPage = Number(url.searchParams.get('per_page') ?? '30');
    const page = Number(url.searchParams.get('page') ?? '1');
    const key = `${String(info.params['owner'])}/${String(info.params['name'])}#${String(info.params['number'])}`;
    const files = (pullRequestFiles.get(key) ?? []).slice((page - 1) * perPage, page * perPage);

    return HttpResponse.json(files);
  }),
  http.post(`${githubAPIURL}/repos/:owner/:name/statuses/:sha`, async (info) => {
    const body = await info.request.json();

    const parsed = commitStatusRequestSchema.safeParse(body);

    if (!parsed.success) {
      return buildValidationFailedResponse();
    }

    const payload = parsed.data;

    const status = {
      repo: `${String(info.params['owner'])}/${String(info.params['name'])}`,
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

function buildValidationFailedResponse(): Response {
  return HttpResponse.json({ message: 'Validation Failed', status: '422' }, { status: 422 });
}
