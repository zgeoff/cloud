import { describe, expect, test } from 'bun:test';
import { requireOnePasswordConnectCredentials } from './require-onepassword-connect-credentials.ts';

describe('requireOnePasswordConnectCredentials', () => {
  test('returns a JSON object unchanged', () => {
    expect(requireOnePasswordConnectCredentials('{"a":1}')).toBe('{"a":1}');
  });

  test('throws when unset or blank', () => {
    expect(() => requireOnePasswordConnectCredentials(undefined)).toThrow('is empty');
    expect(() => requireOnePasswordConnectCredentials(' \n')).toThrow('is empty');
  });

  test('throws when the value is not a JSON object, without echoing it', () => {
    for (const bad of ['not-json-secret', '[1]', '"s"', 'null', '3']) {
      expect(() => requireOnePasswordConnectCredentials(bad)).toThrow('not a JSON object');

      try {
        requireOnePasswordConnectCredentials(bad);
      } catch (error) {
        expect(String(error)).not.toContain(bad);
      }
    }
  });
});
