// The values of atc's security-event contract (zgeoff/atc docs/architecture/remote/oauth.md,
// "Security events", at @zgeoff/atc@4.13.2). Alloy counts each event under these values only and
// turns any other value into `other`, so a label never holds a string the client chose.
export const atcSecurityEvents = {
  // each kind with the outcomes it takes; `suppressed` has no outcome
  outcomes: {
    authorize_started: ['accepted', 'rejected'],
    authorize_invalid: ['rejected'],
    owner_auth: ['succeeded', 'failed'],
    consent: ['allowed', 'denied'],
  },

  // every kind's reasons together: authorize_started's rate limit, authorize_invalid's error codes,
  // owner_auth's failures, consent's empty allow, and each kind a `suppressed` event counts
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
    'none_ticked',
    'authorize_started',
    'authorize_invalid',
    'owner_auth',
    'consent',
  ],

  // the paths atc writes as an event's route; atc writes any other path as `other`
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

  // owner_auth's method: a passkey sign-in, or an enrollment
  methods: ['passkey', 'enrollment_token'],

  // Alloy's counters, under the prefix loki.process gives every metric it makes: one event each,
  // and the count each `suppressed` event reports
  eventsMetric: 'loki_process_custom_atc_security_events_total',
  suppressedMetric: 'loki_process_custom_atc_security_suppressed_events_total',
} as const;
