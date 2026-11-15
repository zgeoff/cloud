// The API's service-token file: each client signs in at `resource` with one of its secrets, whose
// sha256 digest the file holds, and gets the read scope. The file holds no secret.
export function buildPepysServiceTokenFile(
  resource: string,
  digests: Readonly<Record<string, string>>,
): string {
  const clients = Object.fromEntries(
    Object.entries(digests).map(([name, digest]) => [
      name,
      { scopes: ['read'], secretDigests: [digest] },
    ]),
  );

  return JSON.stringify({ resource, clients });
}
