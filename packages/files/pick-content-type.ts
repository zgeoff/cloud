// how many leading bytes pickContentType reads
export const sniffLength = 64;

// The file's media type from its first bytes, never from the uploader's claim: the seven types the
// service serves inline, then PDF, SVG and HTML, which it records but only ever serves as a
// download, and application/octet-stream for anything else.
export function pickContentType(head: Uint8Array): string {
  // one character per byte, of the same value
  const text = String.fromCodePoint(...head);

  if (text.startsWith('\u0089PNG\r\n\u001A\n')) {
    return 'image/png';
  }

  if (text.startsWith('ÿØÿ')) {
    return 'image/jpeg';
  }

  if (text.startsWith('GIF87a') || text.startsWith('GIF89a')) {
    return 'image/gif';
  }

  if (text.startsWith('RIFF') && text.slice(8, 12) === 'WEBP') {
    return 'image/webp';
  }

  if (text.slice(4, 8) === 'ftyp') {
    return pickISOMediaType(text.slice(8, 12));
  }

  // EBML, Matroska's container; only its webm document type plays inline
  if (text.startsWith('\u001AEß£')) {
    return text.includes('webm') ? 'video/webm' : 'application/octet-stream';
  }

  if (text.startsWith('%PDF-')) {
    return 'application/pdf';
  }

  return pickMarkupType(text);
}

const mp4Brands = new Set(['isom', 'iso2', 'iso4', 'iso5', 'iso6', 'mp41', 'mp42', 'avc1', 'dash']);

// the ISO base media file's major brand: AVIF images, then the MP4 video brands; HEIC, QuickTime
// and the audio brands stay downloads
function pickISOMediaType(brand: string): string {
  if (brand === 'avif' || brand === 'avis') {
    return 'image/avif';
  }

  return mp4Brands.has(brand) ? 'video/mp4' : 'application/octet-stream';
}

// SVG and HTML, after an optional byte order mark and leading white space, so the metadata names
// them; the service serves both as a download whatever this finds
function pickMarkupType(text: string): string {
  const start = text
    .replace(/^ï»¿/u, '')
    .trimStart()
    .toLowerCase();

  if (start.startsWith('<svg') || (start.startsWith('<?xml') && start.includes('<svg'))) {
    return 'image/svg+xml';
  }

  if (start.startsWith('<!doctype html') || start.startsWith('<html')) {
    return 'text/html';
  }

  return 'application/octet-stream';
}
