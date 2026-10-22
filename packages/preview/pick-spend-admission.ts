import type { Preview } from './create-preview-store.ts';
import type { ModelRoutePath } from './model-route.ts';
import type { SpendRefusal } from './render-spend-refusal.ts';

export type SpendAdmission =
  | { readonly admitted: true; readonly imp: string }
  | { readonly admitted: false; readonly refusal: SpendRefusal };

// A close marks the preview ended before it removes the proxy, so an ended preview gets no proxy
// that the close would miss.
export function pickSpendAdmission(
  pathname: string,
  route: ModelRoutePath | null,
  phase: Preview['phase'] | null,
): SpendAdmission {
  if (route === null || phase === null || phase === 'ended') {
    return { admitted: false, refusal: { kind: 'no-preview', pathname } };
  }

  return { admitted: true, imp: route.imp };
}
