// The Worker's binding names, which infra sets on the script and the Worker reads from its env:
// the R2 bucket that holds each target's last state, the targets as JSON, and the alert webhook
export const bindingNames = {
  state: 'STATE',
  targets: 'TARGETS',
  alertURL: 'ALERT_URL',
} as const;
