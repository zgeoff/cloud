// the filename goes into a URL path segment and into Content-Disposition
export function isSafeFilename(filename: string): boolean {
  const bytes = new TextEncoder().encode(filename).length;

  return (
    bytes > 0 &&
    bytes <= 255 &&
    filename !== '.' &&
    filename !== '..' &&
    !/[/\\\p{Cc}]/u.test(filename)
  );
}
