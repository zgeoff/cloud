import { expect, test } from 'bun:test';
import { pickContentType } from './pick-content-type.ts';

test.each([
  ['a PNG', 'image/png', [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00]],
  ['a JPEG', 'image/jpeg', [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46]],
  ['a GIF87a', 'image/gif', [...Buffer.from('GIF87a'), 0x01, 0x00]],
  ['a GIF89a', 'image/gif', [...Buffer.from('GIF89a'), 0x01, 0x00]],
  [
    'a WebP',
    'image/webp',
    [...Buffer.from('RIFF'), 0x24, 0x00, 0x00, 0x00, ...Buffer.from('WEBPVP8 ')],
  ],
  ['an AVIF', 'image/avif', [0x00, 0x00, 0x00, 0x1c, ...Buffer.from('ftypavif'), 0x00]],
  ['an AVIF sequence', 'image/avif', [0x00, 0x00, 0x00, 0x1c, ...Buffer.from('ftypavis'), 0x00]],
  ['an MP4 of brand isom', 'video/mp4', [0x00, 0x00, 0x00, 0x20, ...Buffer.from('ftypisom'), 0x00]],
  ['an MP4 of brand mp42', 'video/mp4', [0x00, 0x00, 0x00, 0x18, ...Buffer.from('ftypmp42'), 0x00]],
  [
    'a WebM',
    'video/webm',
    [0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x82, 0x84, ...Buffer.from('webm')],
  ],
  ['a PDF', 'application/pdf', [...Buffer.from('%PDF-1.7\n')]],
  ['an SVG', 'image/svg+xml', [...Buffer.from('<svg xmlns="http://www.w3.org/2000/svg">')]],
  [
    'an SVG behind an XML declaration',
    'image/svg+xml',
    [...Buffer.from('<?xml version="1.0"?>\n<svg>')],
  ],
  ['an HTML document', 'text/html', [...Buffer.from('<!DOCTYPE html><html>')]],
  ['an HTML fragment behind white space', 'text/html', [...Buffer.from('\n  <html><body>')]],
  [
    'an HTML document behind a byte order mark',
    'text/html',
    [0xef, 0xbb, 0xbf, ...Buffer.from('<html>')],
  ],
  [
    'a HEIC image',
    'application/octet-stream',
    [0x00, 0x00, 0x00, 0x18, ...Buffer.from('ftypheic'), 0x00],
  ],
  [
    'a QuickTime movie',
    'application/octet-stream',
    [0x00, 0x00, 0x00, 0x14, ...Buffer.from('ftypqt  '), 0x00],
  ],
  [
    'a Matroska video',
    'application/octet-stream',
    [0x1a, 0x45, 0xdf, 0xa3, 0xa3, 0x42, 0x82, 0x88, ...Buffer.from('matroska')],
  ],
  ['plain text', 'application/octet-stream', [...Buffer.from('hello, world\n')]],
  ['an empty file', 'application/octet-stream', []],
])('it reads %s as %s', (_name, expected, bytes) => {
  expect(pickContentType(Uint8Array.from(bytes))).toBe(expected);
});
