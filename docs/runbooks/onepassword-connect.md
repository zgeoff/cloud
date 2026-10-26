# 1Password Connect for imps

A Connect server in k3s lets a granted imp read vault items with `op read`, through imp's credential
broker. It has no public route.
[1Password Connect](../architecture/workloads/onepassword-connect.md) explains the path.

## The path

A granted imp sends HTTPS to `op-connect.imp.internal`. The broker in imp-host swaps the placeholder
bearer for the real token and forwards to `http://172.17.0.1:18081`. There the host's
`onepassword-connect-relay` socket starts `systemd-socket-proxyd`, which dials the Service's
ClusterIP, `10.43.82.198:8000`, whose target is Connect's API on 8080.

## What holds what

| Where                                                 | Holds                                                      |
| ----------------------------------------------------- | ---------------------------------------------------------- |
| vault `cloud`, item `onepassword-connect-credentials` | the Connect server `imp-connect`'s credentials file (JSON) |
| vault `cloud`, item `onepassword-connect-token`       | the read-only Connect token `imp-agents-ro` (vault `imp`)  |
| vault `imp`                                           | the items imps read; granted to the Connect server only    |
| the Connect Secret in k3s                             | the credentials file, set by Pulumi from `.env`            |
| impd, custom secret `op-connect`                      | the token, with `op-connect.imp.internal` as its only host |

## Add the token to impd

Send the token on stdin. Never put it on a command line.

```sh
op read op://cloud/onepassword-connect-token/credential \
  | impz secret add op-connect --kind custom --hosts op-connect.imp.internal \
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

## Check the NetworkPolicy

Run these on the host (`ssh root@geoffcloud`). None of them takes a secret.

1. Check that k3s's policy controller programs the host's rules:

   ```bash
   nft list ruleset | grep -cE 'chain KUBE-(ROUTER-FORWARD|POD-FW-)'
   ```

   Expect: a count above 0.

2. Check that the policy exists:

   ```bash
   k3s kubectl -n onepassword get networkpolicy onepassword-connect
   ```

3. Call the Service from a pod in another namespace:

   ```bash
   k3s kubectl -n default run connect-netpol-probe --rm -i --restart=Never \
     --image=curlimages/curl:8.11.1 -- curl -sS -m 5 http://10.43.82.198:8000/heartbeat
   ```

   Expect: curl fails with `Failed to connect` or `timed out`, and the pod exits non-zero.

4. Call the Service from the host, the address the relay dials from:

   ```bash
   curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://10.43.82.198:8000/heartbeat
   ```

   Expect: `200`. Then read an item from a granted imp, as in
   [Check from a granted imp](#check-from-a-granted-imp).

## Failures

| Symptom             | Cause                                                     | Fix                                                                                                                                                            |
| ------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 502 from the broker | the relay or Connect is down                              | on the host: `systemctl status onepassword-connect-relay.socket`; check the Service's ClusterIP is still `10.43.82.198`; `k3s kubectl -n onepassword get pods` |
| 403 from Connect    | a write: the token is read-only                           | none: writes are out of scope                                                                                                                                  |
| 401 from Connect    | the token is missing a grant on the vault, or it is wrong | grant the Connect server and token the `imp` vault; re-add the token                                                                                           |
