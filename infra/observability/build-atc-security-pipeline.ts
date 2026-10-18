import { atcSecurityEvents } from './atc-security-events.ts';

// Alloy's pipeline for atc's security events in the gateway's log files at logPath (a glob): a
// counter per stderr event, labelled only with values the contract lists. It forwards no line, so
// no address, client name or other string the client chose leaves it.
export function buildATCSecurityPipeline(logPath: string): string {
  return `
// atc's security events, from the gateway's container log files rather than the Kubernetes log
// API, which joins stdout and stderr; each file is read from its start, so a new pod's first
// events count even when they land before Alloy finds the file
loki.source.file "atc_security" {
  targets = [{__path__ = ${toAlloyString(logPath)}}]
  file_match {
    enabled = true
  }
  forward_to = [loki.process.atc_security.receiver]
}

// counters only: loki.source.kubernetes "pods" ships the same lines to Loki
loki.process "atc_security" {
  forward_to = []

  stage.cri {}

  // the cutoff for history: an event older than the time Alloy takes to find a new file is one
  // that a start without saved positions reads again, and it raises no alert
  stage.drop {
    older_than          = "2m"
    drop_counter_reason = "atc security event before the cutoff"
  }

  stage.match {
    selector      = ${toAlloyString(String.raw`{stream="stderr"} |~ "^atc security \\{"`)}
    pipeline_name = "atc_security_event"

    stage.regex {
      expression = ${toAlloyString(String.raw`^atc security (?P<event>\{.*\})$`)}
    }

    stage.json {
      source      = "event"
      expressions = { kind = "kind", outcome = "outcome", reason = "reason", route = "route", method = "method", count = "count" }
    }

    // the kind only with an outcome the contract gives it, and the outcome only with its kind
    stage.template {
      source   = "kind"
      template = ${toAlloyString(buildKindTemplate())}
    }

    stage.template {
      source   = "outcome"
      template = ${toAlloyString('{{ if eq .kind "suppressed" }}none{{ else if eq .kind "other" }}other{{ else }}{{ .outcome }}{{ end }}')}
    }

    stage.template {
      source   = "reason"
      template = ${toAlloyString(buildAllowlistTemplate(atcSecurityEvents.reasons))}
    }

    stage.template {
      source   = "route"
      template = ${toAlloyString(buildAllowlistTemplate(atcSecurityEvents.routes))}
    }

    stage.template {
      source   = "method"
      template = ${toAlloyString(buildAllowlistTemplate(atcSecurityEvents.methods))}
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
        template = ${toAlloyString('{{ if regexMatch `^[0-9]{1,9}$` (toString .Value) }}{{ .Value }}{{ else }}0{{ end }}')}
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
`;
}

// An Alloy string literal: Alloy's escapes are a superset of JSON's.
function toAlloyString(value: string): string {
  return JSON.stringify(value);
}

// The kind when the kind and the outcome make a pair of the contract, `suppressed` for a suppressed
// event, and `other` for anything else.
function buildKindTemplate(): string {
  const pairs = Object.entries(atcSecurityEvents.outcomes).map(
    ([kind, outcomes]) => `${kind}\\.(${outcomes.join('|')})`,
  );

  return [
    `{{ if regexMatch \`^(${pairs.join('|')})$\` (printf "%v.%v" .kind .outcome) }}{{ .kind }}`,
    '{{ else if eq (toString .kind) "suppressed" }}suppressed',
    '{{ else }}other{{ end }}',
  ].join('');
}

// The value when the contract lists it, `none` when the event has none, and `other` for anything
// else.
function buildAllowlistTemplate(values: readonly string[]): string {
  const alternatives = values.map((value) => value.replaceAll(/[.]/gu, String.raw`\.`)).join('|');

  return `{{ if not .Value }}none{{ else if regexMatch \`^(${alternatives})$\` (toString .Value) }}{{ .Value }}{{ else }}other{{ end }}`;
}
