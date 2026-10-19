import { expect, test } from 'bun:test';
import { buildUploadRequest } from './build-upload-request.ts';

test('it posts the file and each field as a multipart form with the Authorization header', async () => {
  const request = buildUploadRequest({
    authorization: 'Bearer abc123',
    file: new File(['hello'], 'note.txt'),
    fields: { expires: '30d', label: 'release notes' },
  });

  const contentType = request.headers.get('Content-Type');

  const body = await request.text();

  expect(request.method).toBe('POST');
  expect(request.url).toBe('http://localhost/api/files');
  expect(request.headers.get('Authorization')).toBe('Bearer abc123');
  expect(contentType).toStartWith('multipart/form-data; boundary=');
  expect(body).toInclude('name="file"; filename="note.txt"');
  expect(body).toInclude('\r\n\r\nhello\r\n');
  expect(body).toInclude('name="expires"\r\n\r\n30d\r\n');
  expect(body).toInclude('name="label"\r\n\r\nrelease notes\r\n');
});

test('it sends no Authorization header when none is given', () => {
  const request = buildUploadRequest({
    authorization: undefined,
    file: new File(['hello'], 'note.txt'),
  });

  expect(request.headers.has('Authorization')).toBeFalse();
});
