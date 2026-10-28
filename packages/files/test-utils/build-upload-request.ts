interface UploadRequestOptions {
  // the whole Authorization header, or undefined for none
  readonly authorization: string | undefined;
  readonly file: File;
  readonly fields?: Readonly<Record<string, string>>;
}

export function buildUploadRequest(options: UploadRequestOptions): Request {
  const form = new FormData();

  form.append('file', options.file);

  for (const [name, value] of Object.entries(options.fields ?? {})) {
    form.append(name, value);
  }

  const headers = new Headers();

  if (options.authorization !== undefined) {
    headers.set('Authorization', options.authorization);
  }

  return new Request('http://localhost/api/files', { method: 'POST', headers, body: form });
}
