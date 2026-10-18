import { expect, test } from 'bun:test';
import { buildATCSecurityPipeline } from './build-atc-security-pipeline.ts';

test("it counts the gateway's stderr security events from the end of its log files, under the contract's values only, and forwards no line", () => {
  expect(buildATCSecurityPipeline('/var/log/pods/atc_atc-gateway-*/atc-gateway/*.log'))
    .toStrictEqual(`
// atc's security events, from the gateway's container log files rather than the Kubernetes log
// API, which joins stdout and stderr; without a saved position a file is read from its end, so a
// first start counts no earlier sign-in
loki.source.file "atc_security" {
  targets       = [{__path__ = "/var/log/pods/atc_atc-gateway-*/atc-gateway/*.log"}]
  tail_from_end = true
  file_match {
    enabled = true
  }
  forward_to = [loki.process.atc_security.receiver]
}

// counters only: loki.source.kubernetes "pods" ships the same lines to Loki
loki.process "atc_security" {
  forward_to = []

  stage.cri {}

  stage.match {
    selector      = "{stream=\\"stderr\\"} |~ \\"^atc security \\\\\\\\{\\""
    pipeline_name = "atc_security_event"

    stage.regex {
      expression = "^atc security (?P<event>\\\\{.*\\\\})$"
    }

    stage.json {
      source      = "event"
      expressions = { kind = "kind", outcome = "outcome", reason = "reason", route = "route", method = "method", count = "count" }
    }

    // the kind only with an outcome the contract gives it, and the outcome only with its kind
    stage.template {
      source   = "kind"
      template = "{{ if regexMatch \`^(authorize_started\\\\.(accepted|rejected)|authorize_invalid\\\\.(rejected)|owner_auth\\\\.(succeeded|failed)|consent\\\\.(allowed|denied))$\` (printf \\"%v.%v\\" .kind .outcome) }}{{ .kind }}{{ else if eq (toString .kind) \\"suppressed\\" }}suppressed{{ else }}other{{ end }}"
    }

    stage.template {
      source   = "outcome"
      template = "{{ if eq .kind \\"suppressed\\" }}none{{ else if eq .kind \\"other\\" }}other{{ else }}{{ .outcome }}{{ end }}"
    }

    stage.template {
      source   = "reason"
      template = "{{ if not .Value }}none{{ else if regexMatch \`^(rate_limited|invalid_client|client_disabled|invalid_redirect|unauthorized_client|unsupported_response_type|invalid_request|invalid_scope|invalid_target|bad_host|bad_origin|other|assertion_failed|locked|expired|not_enrolled|invalid_token|none_ticked|authorize_started|authorize_invalid|owner_auth|consent)$\` (toString .Value) }}{{ .Value }}{{ else }}other{{ end }}"
    }

    stage.template {
      source   = "route"
      template = "{{ if not .Value }}none{{ else if regexMatch \`^(/|/mcp|/oauth2/authorize|/oauth2/token|/oauth2/revoke|/login|/enroll|/consent|/error|/healthz|/readyz|/\\\\.well-known/oauth-authorization-server|/\\\\.well-known/oauth-protected-resource|/\\\\.well-known/oauth-protected-resource/mcp|other)$\` (toString .Value) }}{{ .Value }}{{ else }}other{{ end }}"
    }

    stage.template {
      source   = "method"
      template = "{{ if not .Value }}none{{ else if regexMatch \`^(passkey|enrollment_token)$\` (toString .Value) }}{{ .Value }}{{ else }}other{{ end }}"
    }

    stage.labels {
      values = { kind = "", outcome = "", reason = "", route = "", method = "" }
    }

    stage.label_keep {
      values = ["kind", "outcome", "reason", "route", "method"]
    }

    // every label value comes from a closed set, so a series may idle long: a series that Alloy
    // removes and makes again starts at its new count
    stage.metrics {
      metric.counter {
        name              = "atc_security_events_total"
        description       = "atc security events, one per line"
        match_all         = true
        action            = "inc"
        max_idle_duration = "720h"
      }
    }

    // a suppressed event reports how many events of its reason's kind atc's burst cap dropped
    stage.match {
      selector = "{kind=\\"suppressed\\"}"

      stage.template {
        source   = "count"
        template = "{{ if regexMatch \`^[0-9]{1,9}$\` (toString .Value) }}{{ .Value }}{{ else }}0{{ end }}"
      }

      stage.metrics {
        metric.counter {
          name              = "atc_security_suppressed_events_total"
          description       = "atc security events that atc's burst cap dropped"
          source            = "count"
          action            = "add"
          max_idle_duration = "720h"
        }
      }
    }
  }
}
`);
});
