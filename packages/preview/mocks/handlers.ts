import { HttpResponse, http } from 'msw';
import { githubAPIURL } from './github-api-url.ts';
import { composeFiles, issueComments } from './github-state.ts';

// GitHub's REST endpoints that the service calls, with GitHub's status codes and the fields the
// service reads (https://docs.github.com/en/rest/repos/contents,
// https://docs.github.com/en/rest/issues/comments). A missing file or comment is a 404.
export const handlers = [
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
      .map((comment) => ({ id: comment.id, body: comment.body }));

    return HttpResponse.json(comments);
  }),
  http.post(`${githubAPIURL}/repos/:owner/:name/issues/:number/comments`, async (info) => {
    const payload = (await info.request.json()) as { readonly body: string };

    const comment = {
      id: 9000 + issueComments.length,
      repo: `${String(info.params['owner'])}/${String(info.params['name'])}`,
      number: Number(info.params['number']),
      body: payload.body,
    };

    issueComments.push(comment);

    return HttpResponse.json({ id: comment.id, body: comment.body }, { status: 201 });
  }),
  http.patch(`${githubAPIURL}/repos/:owner/:name/issues/comments/:id`, async (info) => {
    const payload = (await info.request.json()) as { readonly body: string };
    const comment = issueComments.find((candidate) => candidate.id === Number(info.params['id']));

    if (comment === undefined) {
      return HttpResponse.json({ message: 'Not Found', status: '404' }, { status: 404 });
    }

    comment.body = payload.body;

    return HttpResponse.json({ id: comment.id, body: comment.body });
  }),
];
