// atc's security-event contract (zgeoff/atc docs/architecture/remote/oauth.md, "Security
// events", at @zgeoff/atc@7.21.1)
export const atcSecurityEvents = {
  // `suppressed` has no outcome
  outcomes: {
    authorize_started: ['accepted', 'rejected'],
    authorize_invalid: ['rejected'],
    owner_auth: ['succeeded', 'failed'],
    consent: ['allowed', 'denied'],
    token_exchange: ['succeeded', 'rejected'],
    bearer: ['rejected'],
    bad_host: ['rejected'],
    bad_origin: ['rejected'],
  },

  reasons: [
    'rate_limited',
    'invalid_client',
    'client_disabled',
    'invalid_redirect',
    'unauthorized_client',
    'unsupported_response_type',
    'invalid_request',
    'invalid_scope',
    'invalid_target',
    'bad_host',
    'bad_origin',
    'other',
    'assertion_failed',
    'locked',
    'expired',
    'not_enrolled',
    'invalid_token',
    'host_not_allowed',
    'origin_not_allowed',
    'missing',
    'malformed',
    'invalid_grant',
    'unsupported_grant_type',
    'temporarily_unavailable',
    'none_ticked',
    'authorize_started',
    'authorize_invalid',
    'owner_auth',
    'consent',
    'token_exchange',
    'bearer',
  ],

  // atc writes any other path as `other`
  routes: [
    '/',
    '/mcp',
    '/oauth2/authorize',
    '/oauth2/token',
    '/oauth2/revoke',
    '/login',
    '/enroll',
    '/consent',
    '/error',
    '/healthz',
    '/readyz',
    '/.well-known/oauth-authorization-server',
    '/.well-known/oauth-protected-resource',
    '/.well-known/oauth-protected-resource/mcp',
    'other',
  ],

  methods: ['passkey', 'enrollment_token'],

  // loki.process gives every metric it makes this prefix
  eventsMetric: 'loki_process_custom_atc_security_events_total',
  suppressedMetric: 'loki_process_custom_atc_security_suppressed_events_total',
} as const;
