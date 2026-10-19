// A filename the service puts in a URL path segment and in Content-Disposition: 1 to 255 bytes of
// UTF-8, no slash, backslash or control character, and neither . nor ..
export function isSafeFilename(filename: string): boolean {
  const bytes = new TextEncoder().encode(filename).length;

  return (
    bytes > 0 &&
    bytes <= 255 &&
    filename !== '.' &&
    filename !== '..' &&
    ![...filename].some((character) => isForbiddenCharacter(character))
  );
}

function isForbiddenCharacter(character: string): boolean {
  const code = character.codePointAt(0) ?? 0;

  return character === '/' || character === '\\' || code < 0x20 || code === 0x7f;
}
