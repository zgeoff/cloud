import { expect, test } from 'bun:test';
import { buildUploadRequest } from './build-upload-request.ts';

test('it posts the file and each field as a multipart form with the Authorization header', async () => {
  const request = buildUploadRequest({
    authorization: 'Bearer abc123',
    file: new File(['hello'], 'note.txt'),
    fields: { expires: '30d', label: 'release notes' },
  });

  const contentType = request.headers.get('Content-Type');

  const form = await request.formData();

  const file = form.get('file');

  if (!(file instanceof File)) {
    throw new TypeError('the form holds no file');
  }

  expect(request.method).toBe('POST');
  expect(request.url).toBe('http://localhost/api/files');
  expect(request.headers.get('Authorization')).toBe('Bearer abc123');
  expect(contentType).toStartWith('multipart/form-data; boundary=');

  const text = await file.text();

  expect(text).toBe('hello');
  expect(file.name).toBe('note.txt');
  expect(form.get('expires')).toBe('30d');
  expect(form.get('label')).toBe('release notes');
});

test('it sends no Authorization header when none is given', () => {
  const request = buildUploadRequest({
    authorization: undefined,
    file: new File(['hello'], 'note.txt'),
  });

  expect(request.headers.has('Authorization')).toBeFalse();
});
