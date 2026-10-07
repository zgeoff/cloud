import { describe, expect, test } from 'bun:test';
import { buildOnePasswordConnectProxyConfig } from './build-onepassword-connect-proxy-config.ts';

describe('buildOnePasswordConnectProxyConfig', () => {
  test('allows each listed address exactly and denies by default', () => {
    const config = buildOnePasswordConnectProxyConfig(['104.250.100.18', '10.0.0.1']);

    expect(config).toContain('geo $http_cf_connecting_ip $connect_source_allowed {');
    expect(config).toContain('default 0;');
    expect(config).toContain('104.250.100.18/32 1;');
    expect(config).toContain('10.0.0.1/32 1;');
    expect(config).toContain('if ($connect_source_allowed = 0) {\n    return 403;');
  });

  test('allows only GET and HEAD', () => {
    const config = buildOnePasswordConnectProxyConfig(['104.250.100.18']);

    expect(config).toContain('if ($request_method !~ ^(GET|HEAD)$) {\n    return 405;');
  });

  test('proxies to Connect without logging the authorization header', () => {
    const config = buildOnePasswordConnectProxyConfig(['104.250.100.18']);

    expect(config).toContain('proxy_pass http://127.0.0.1:8080;');
    expect(config).toContain('listen 8000;');
    expect(config).toContain('server_tokens off;');
    expect(config).not.toContain('authorization');
    expect(config).not.toContain('log_format');
  });

  test('rejects anything but a plain IPv4 address', () => {
    for (const bad of [
      '',
      '1.2.3',
      '1.2.3.4/24',
      '256.1.1.1',
      '01.2.3.4',
      '::1',
      '1.2.3.4 1; } server { ',
      '1.2.3.4\n',
    ]) {
      expect(() => buildOnePasswordConnectProxyConfig([bad])).toThrow('plain IPv4');
    }
  });

  test('rejects an empty list', () => {
    expect(() => buildOnePasswordConnectProxyConfig([])).toThrow('at least one');
  });
});
