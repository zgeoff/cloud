import { expect, test } from 'bun:test';
import { loadFilesConfig } from './load-files-config.ts';

test('it loads every value, with the hashes in lowercase', () => {
  expect(
    loadFilesConfig({
      FILES_PORT: '9090',
      FILES_DATA_DIR: '/data',
      FILES_PUBLIC_URL: 'https://files.example.com',
      FILES_AGENT_TOKEN_SHA256: 'A'.repeat(64),
      FILES_OWNER_TOKEN_SHA256: 'b'.repeat(64),
    }),
  ).toStrictEqual({
    port: 9090,
    dataDir: '/data',
    publicURL: 'https://files.example.com',
    tokenHashes: { agent: 'a'.repeat(64), owner: 'b'.repeat(64) },
  });
});

test('it listens on port 8080 when FILES_PORT is unset', () => {
  expect(
    loadFilesConfig({
      FILES_DATA_DIR: '/data',
      FILES_PUBLIC_URL: 'https://files.example.com',
      FILES_AGENT_TOKEN_SHA256: 'a'.repeat(64),
      FILES_OWNER_TOKEN_SHA256: 'b'.repeat(64),
    }).port,
  ).toBe(8080);
});

test.each([
  ['FILES_DATA_DIR', 'FILES_DATA_DIR is not set'],
  ['FILES_PUBLIC_URL', 'FILES_PUBLIC_URL is not set'],
  ['FILES_AGENT_TOKEN_SHA256', 'FILES_AGENT_TOKEN_SHA256 is not set'],
  ['FILES_OWNER_TOKEN_SHA256', 'FILES_OWNER_TOKEN_SHA256 is not set'],
])('it refuses to start without %s', (name, message) => {
  const env: Record<string, string> = {
    FILES_DATA_DIR: '/data',
    FILES_PUBLIC_URL: 'https://files.example.com',
    FILES_AGENT_TOKEN_SHA256: 'a'.repeat(64),
    FILES_OWNER_TOKEN_SHA256: 'b'.repeat(64),
  };

  delete env[name];
  expect(() => loadFilesConfig(env)).toThrowWithMessage(Error, message);
});

test('it refuses a token hash that is not 64 hex characters', () => {
  expect(() =>
    loadFilesConfig({
      FILES_DATA_DIR: '/data',
      FILES_PUBLIC_URL: 'https://files.example.com',
      FILES_AGENT_TOKEN_SHA256: 'plain-agent-token',
      FILES_OWNER_TOKEN_SHA256: 'b'.repeat(64),
    }),
  ).toThrowWithMessage(
    Error,
    'FILES_AGENT_TOKEN_SHA256 must be a SHA-256 digest as 64 hex characters',
  );
});

test('it refuses one hash for both roles', () => {
  expect(() =>
    loadFilesConfig({
      FILES_DATA_DIR: '/data',
      FILES_PUBLIC_URL: 'https://files.example.com',
      FILES_AGENT_TOKEN_SHA256: 'c'.repeat(64),
      FILES_OWNER_TOKEN_SHA256: 'C'.repeat(64),
    }),
  ).toThrowWithMessage(Error, 'FILES_AGENT_TOKEN_SHA256 and FILES_OWNER_TOKEN_SHA256 must differ');
});

test.each([
  ['https://files.example.com/'],
  ['https://files.example.com/drop'],
  ['ftp://files.example.com'],
])('it refuses the public URL %s', (publicURL) => {
  expect(() =>
    loadFilesConfig({
      FILES_DATA_DIR: '/data',
      FILES_PUBLIC_URL: publicURL,
      FILES_AGENT_TOKEN_SHA256: 'a'.repeat(64),
      FILES_OWNER_TOKEN_SHA256: 'b'.repeat(64),
    }),
  ).toThrowWithMessage(Error, 'FILES_PUBLIC_URL must be an http or https origin with no path');
});

test.each([['0'], ['65536'], ['80.5'], ['http']])('it refuses the port %s', (port) => {
  expect(() =>
    loadFilesConfig({
      FILES_PORT: port,
      FILES_DATA_DIR: '/data',
      FILES_PUBLIC_URL: 'https://files.example.com',
      FILES_AGENT_TOKEN_SHA256: 'a'.repeat(64),
      FILES_OWNER_TOKEN_SHA256: 'b'.repeat(64),
    }),
  ).toThrowWithMessage(Error, 'FILES_PORT must be a port number');
});
