# 1Password Connect for imps

**PENDING:** Connect is built, not deployed. A Connect server in k3s lets a granted imp read vault
items with `op read`, through imp's credential broker. The design is in
[the architecture](../architecture.md#secrets-for-imps-1password-connect). Tracked as GEO-120.

## What holds what

| Where                                                 | Holds                                                      |
| ----------------------------------------------------- | ---------------------------------------------------------- |
| vault `cloud`, item `onepassword-connect-credentials` | the Connect server `imp-connect`'s credentials file (JSON) |
| vault `cloud`, item `onepassword-connect-token`       | the Connect access token the broker presents               |
| vault `imp`                                           | the items imps read; granted to the Connect server only    |
| the Connect Secret in k3s                             | the credentials file, set by Pulumi from `.env`            |
| impd, custom secret `op-connect`                      | the token, with `op-connect.geoff.cloud` as its only host  |

## Add the token to impd

Send the token on stdin. Never put it on a command line.

```sh
op read op://cloud/onepassword-connect-token/credential \
  | imp secret add op-connect --kind custom --hosts op-connect.geoff.cloud \
      --header authorization --scheme bearer
```

## Rotate

- **The token:** mint a new one in 1Password, update the item `onepassword-connect-token`, and run
  the command above with `--replace`.
- **The credentials file:** update the item `onepassword-connect-credentials`, then `bun run up`.
  Pulumi replaces the Secret and the Deployment rolls the pod.

## Check from a granted imp

```sh
OP_CONNECT_HOST=https://op-connect.geoff.cloud OP_CONNECT_TOKEN=imp-broker-placeholder \
  op read op://imp/<item>/<field>
```

The broker swaps the placeholder for the real token on the way out.

## Failures

| Symptom             | Cause                                                              | Fix                                                                                       |
| ------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| 403 from the proxy  | the source IP changed: the allowlist is the VM's public IPv4       | read `geoffcloudIPv4` from Pulumi's outputs, then `bun run up` to update the proxy config |
| 405 from the proxy  | the request was not GET or HEAD; Connect is read-only from outside | none: writes are out of scope                                                             |
| 401 from Connect    | the token is missing a grant on the vault, or it is wrong          | grant the Connect server and token the `imp` vault; re-add the token                      |
| 502 from the tunnel | the Connect pod is not ready                                       | `kubectl -n onepassword get pods` and the `connect-api` logs                              |

The 403 body comes from nginx. The proxy's access log goes to the pod's stdout and never records the
`Authorization` header.
