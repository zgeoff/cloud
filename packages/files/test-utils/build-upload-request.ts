interface UploadRequestOptions {
  // the whole Authorization header, or undefined for none
  readonly authorization: string | undefined;
  readonly file: File;

  // the form's other fields, such as expires and label
  readonly fields?: Readonly<Record<string, string>>;
}

// the multipart POST to /api/files that the agents' curl line sends
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
