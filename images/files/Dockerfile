# The files service image: the service compiled to one binary by `bun build --compile`, on the
# distroless base that images/atc-gateway/versions.env pins, as the nonroot user. The build context
# holds the binary as ./files, which scripts/write-files-image-context.sh compiles; nothing is
# downloaded inside the build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY --chmod=0555 files /usr/local/bin/files
# the volume holds the files and the metadata file; Kubernetes mounts it at /data
ENV FILES_DATA_DIR=/data FILES_PORT=8080
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/files"]
