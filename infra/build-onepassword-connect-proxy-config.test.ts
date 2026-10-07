import { describe, expect, test } from 'bun:test';
import { buildOnePasswordConnectProxyConfig } from './build-onepassword-connect-proxy-config.ts';

describe('buildOnePasswordConnectProxyConfig', () => {
  test('allows only GET and HEAD', () => {
    const config = buildOnePasswordConnectProxyConfig();

    expect(config).toContain('if ($request_method !~ ^(GET|HEAD)$) {\n    return 405;');
  });

  test('has no source allowlist', () => {
    const config = buildOnePasswordConnectProxyConfig();

    expect(config).not.toContain('geo ');
    expect(config).not.toContain('cf_connecting_ip');
    expect(config).not.toContain('return 403');
  });

  test('proxies to Connect without logging the authorization header', () => {
    const config = buildOnePasswordConnectProxyConfig();

    expect(config).toContain('proxy_pass http://127.0.0.1:8080;');
    expect(config).toContain('listen 8000;');
    expect(config).toContain('server_tokens off;');
    expect(config).not.toContain('authorization');
    expect(config).not.toContain('log_format');
  });
});
