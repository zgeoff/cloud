import { match } from 'ts-pattern';

export type SpendRefusal =
  | { readonly kind: 'no-preview'; readonly pathname: string }
  | { readonly kind: 'no-proxy' }
  | { readonly kind: 'no-answer' };

// each refusal in the model API's error shape, so the model client in the preview reads it as one
export function renderSpendRefusal(refusal: SpendRefusal): Response {
  return match(refusal)
    .with({ kind: 'no-preview' }, (noPreview) =>
      renderAPIError(
        404,
        'not_found_error',
        `no preview holds the model route ${noPreview.pathname}`,
      ),
    )
    .with({ kind: 'no-proxy' }, () =>
      renderAPIError(503, 'api_error', 'the preview service could not start the counting proxy'),
    )
    .with({ kind: 'no-answer' }, () =>
      renderAPIError(502, 'api_error', 'the counting proxy did not answer'),
    )
    .exhaustive();
}

function renderAPIError(status: number, type: string, message: string): Response {
  return Response.json({ type: 'error', error: { type, message } }, { status });
}
