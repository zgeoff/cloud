import type { Upload } from './types.ts';

// the types a browser may render in place: images and video, none of which can run script
const inlineTypes = new Set([
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/avif',
  'video/mp4',
  'video/webm',
]);

// A file's response headers: an inline type keeps its type, and anything else, SVG and HTML too,
// is an application/octet-stream attachment. Caches keep a file 5 minutes at most, so a removed or
// expired file soon leaves Cloudflare's cache.
export function buildFileHeaders(upload: Pick<Upload, 'contentType' | 'filename'>) {
  const inline = inlineTypes.has(upload.contentType);

  return {
    'Content-Type': inline ? upload.contentType : 'application/octet-stream',
    'Content-Disposition': `${inline ? 'inline' : 'attachment'}; ${renderFilenameParameters(upload.filename)}`,
    'Cache-Control': 'public, max-age=300',
  };
}

// RFC 6266: an ASCII fallback with each other character as _, then the exact name in RFC 8187's
// UTF-8 form
function renderFilenameParameters(filename: string): string {
  const fallback = filename.replaceAll(/[^\u0020-\u007E]|["\\]/gu, '_');

  return `filename="${fallback}"; filename*=UTF-8''${encodeRFC8187(filename)}`;
}

function encodeRFC8187(value: string): string {
  return encodeURIComponent(value).replaceAll(
    /['()*]/gu,
    (character) => `%${(character.codePointAt(0) ?? 0).toString(16).toUpperCase()}`,
  );
}
