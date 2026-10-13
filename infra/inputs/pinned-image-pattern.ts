// a release pin names its tag for the reader and its digest for the runtime
export const pinnedImagePattern =
  /^[^\s@:]+(?::\d+)?(?:\/[^\s@:]+)*:[^\s@:]+@sha256:[0-9a-f]{64}$/u;
