# The files service

The files service holds the screenshots and other files that agents link from pull requests, at
`files.geoff.cloud`. An agent uploads a file with a role token and gets back a URL of the form
`https://files.geoff.cloud/<id>/<filename>`. Anyone with that URL can read the file until it
expires, and then the service answers 404 for it. GitHub's image proxy fetches each image in a pull
request without signing in, and imps cannot reach the tailnet, so the service sits on a public route
rather than the tailnet ([public ingress](../network/public-ingress.md)). The service runs in k3s as
one pod with its own volume, and a nightly job backs that volume up to R2.

## Uploads and roles

The service knows two roles, `agent` and `owner`, each with one bearer token. It holds only the
SHA-256 hash of each token, which Pulumi builds from the tokens in 1Password and puts in a
Kubernetes Secret, so the cluster never holds a token itself. A write without a token, or with one
whose hash matches neither role, gets 401.

| Action              | `agent`                                  | `owner`      |
| ------------------- | ---------------------------------------- | ------------ |
| Upload              | yes, with a capped expiry, never `never` | any expiry   |
| List, read the info | `agent` uploads only                     | every upload |
| Change an expiry    | no                                       | yes          |
| Remove              | `agent` uploads only                     | yes          |

Every agent shares the one `agent` token, so the service cannot tell one agent from another. An
`owner` upload is invisible to the `agent` token: the service answers 404 for it rather than 403, so
the agent token cannot learn that the upload exists.

The service sets each upload's ID, size, SHA-256, upload time, uploader and content type itself. The
uploader is the role. The client sets the filename, an optional label and link, and the expiry,
which has a short default. The ID is 22 random characters from the 62 letters and digits, so nobody
can guess a link they were not given.

The API is a typed oRPC layer under `/api`. One contract defines each procedure's input and output,
and the package exports it, so a client builds on the same types as the service.

## Serving a file

The service decides a file's content type from the file's first bytes when it receives the upload,
and never from the filename or the client's header. A response carries that type and `inline` only
for a raster image or a video that a browser plays without running code: PNG, JPEG, GIF, WebP, AVIF,
MP4 and WebM. Every other file, SVG and HTML included, goes out as `application/octet-stream` with
an `attachment` disposition, because a browser runs the scripts in those. Every response, a 404
included, carries `X-Content-Type-Options: nosniff` and the policy `default-src 'none'; sandbox`, so
a browser neither guesses a different type nor runs anything that slips through.

The service answers 404 for a URL whose filename differs from the stored one, and for an unknown or
expired ID. The filename is in the URL for the reader's sake, and a wrong one is treated as a wrong
link.

## Storage and expiry

The pod keeps the files and one SQLite database of their metadata on a local-path volume that k3s
retains when the claim goes away. The service writes each upload to a staging directory first,
hashes it as it streams, then renames it into place, and only then records its row. A crash during
an upload therefore leaves a staged file and no row, and the service clears the staging directory
when it starts.

The service refuses a file over its size cap with 413, and refuses any upload with 507 when the
volume would keep less than a fixed reserve free, so a full volume never breaks the database.

An expired upload stops serving at once, because each read checks the expiry. An in-process sweep
runs when the service starts and then every hour. It removes each expired file first and its row
second, so a crash between the two leaves a row whose file is gone, which reads as 404, never a file
that nothing lists.

## Backup and restore

The `files-backup` CronJob runs nightly in the atc gateway's backup image. It copies the database
with SQLite's online backup, checks the copy's integrity, and takes one restic snapshot of the copy
and the files into the `files` repository in R2. A restore checks the snapshot's database copy
before it changes anything, then restores the files, puts the database in place, and removes each
file that the restored database does not list. [The runbook](../../runbooks/files.md) covers both.

## Deployment

The `files image` workflow builds the service into one binary on a distroless base and publishes it
from `main` to GHCR. The Pulumi program deploys it only when stack config `files` names the image by
digest and the public hostname, so the deploy needs the owner's change to stack config. The pod runs
as a nonroot user on a read-only root filesystem with every capability dropped.
