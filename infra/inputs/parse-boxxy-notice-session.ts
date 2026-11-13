// The boxxy server's notice session, in a secret stack config key of its own: the gateway ID
// reaches the owner's session, so it stays out of the public Pulumi.prod.yaml and the preview
export const boxxyNoticeSessionKey = 'boxxyNoticeSession';

// the server's own rule for a gateway ID, `<daemon>.<incarnation>.<id>`, so a value this passes
// never stops the server
const gatewayID = /^[^.]+\.[^.]+\..+$/u;

// CI logs are public, so the refusal never quotes the value
export function parseBoxxyNoticeSession(text: string): string {
  if (!gatewayID.test(text)) {
    throw new Error(
      `stack config "${boxxyNoticeSessionKey}" must be the notice session's gateway ID, <daemon>.<incarnation>.<id>, as atc_sessions_list prints it through the gateway`,
    );
  }

  return text;
}
