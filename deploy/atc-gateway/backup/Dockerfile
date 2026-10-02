# Backup and restore for the gateway's SQLite state: restic plus sqlite3, for a
# consistent copy of a live database before upload.
ARG RESTIC_IMAGE
FROM ${RESTIC_IMAGE}
RUN apk add --no-cache sqlite
COPY --chmod=0555 backup.sh /usr/local/bin/atc-gateway-backup
ENTRYPOINT ["/usr/local/bin/atc-gateway-backup"]
