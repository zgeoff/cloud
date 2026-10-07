# 1Password Connect for imps

**PENDING:** Connect is built, not deployed. A Connect server in k3s lets a granted imp read vault
items with `op read`, through imp's credential broker. It has no public route. The design is in
[the architecture](../architecture.md#secrets-for-imps-1password-connect). Tracked as GEO-120.

## The path

A granted imp sends HTTPS to `op-connect.imp.internal`. The broker in imp-host swaps the placeholder
bearer for the real token and forwards to `http://172.17.0.1:18081`. There the host's
`onepassword-connect-relay` socket starts `systemd-socket-proxyd`, which dials the Service's
ClusterIP, `10.43.82.198:8000`. That is the nginx proxy in the Connect pod, which passes GET and
HEAD only.

## What holds what

| Where                                                 | Holds                                                      |
| ----------------------------------------------------- | ---------------------------------------------------------- |
| vault `cloud`, item `onepassword-connect-credentials` | the Connect server `imp-connect`'s credentials file (JSON) |
| vault `cloud`, item `onepassword-connect-token`       | the Connect access token the broker presents               |
| vault `imp`                                           | the items imps read; granted to the Connect server only    |
| the Connect Secret in k3s                             | the credentials file, set by Pulumi from `.env`            |
| impd, custom secret `op-connect`                      | the token, with `op-connect.imp.internal` as its only host |

## Add the token to impd

Send the token on stdin. Never put it on a command line.

```sh
op read op://cloud/onepassword-connect-token/credential \
  | imp secret add op-connect --kind custom --hosts op-connect.imp.internal \
      --header authorization --scheme bearer --upstream http://172.17.0.1:18081
```

Replacing an older binding (the secret bound to a different host) needs `--replace --rebind`.

## Rotate

- **The token:** mint a new one in 1Password, update the item `onepassword-connect-token`, and run
  the command above with `--replace`.
- **The credentials file:** update the item `onepassword-connect-credentials`, then `bun run up`.
  Pulumi replaces the Secret and the Deployment rolls the pod.

## Check from a granted imp

```sh
OP_CONNECT_HOST=https://op-connect.imp.internal OP_CONNECT_TOKEN=imp-broker-placeholder \
  op read op://imp/<item>/<field>
```

The broker swaps the placeholder for the real token on the way out.

## Failures

| Symptom             | Cause                                                      | Fix                                                                                                                                                            |
| ------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 502 from the broker | the relay or Connect is down                               | on the host: `systemctl status onepassword-connect-relay.socket`; check the Service's ClusterIP is still `10.43.82.198`; `k3s kubectl -n onepassword get pods` |
| 405 from the proxy  | the request was not GET or HEAD; Connect is read-only here | none: writes are out of scope                                                                                                                                  |
| 401 from Connect    | the token is missing a grant on the vault, or it is wrong  | grant the Connect server and token the `imp` vault; re-add the token                                                                                           |

The proxy's access log goes to the pod's stdout and never records the `Authorization` header.
