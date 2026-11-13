# The boxxy server image: the server compiled to one binary by `bun build --compile` from
# deploy/boxxy/server.ts and the @boxxy/server package, on the base that images/boxxy/versions.env
# pins, which carries git for a rules checkout, as uid 65532. The image holds no rules: the pod
# mounts the rules sidecar's checkout at /rules. The build context holds the binary as
# ./boxxy-server, which scripts/write-boxxy-image-context.sh writes; nothing is downloaded inside
# the build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY --chmod=0555 boxxy-server /usr/local/bin/boxxy-server
# the pod mounts the configuration file here from a ConfigMap, and the volume for the store at /data
ENV BOXXY_CONFIG=/etc/boxxy/config.json
USER 65532
EXPOSE 8090 8091
ENTRYPOINT ["/usr/local/bin/boxxy-server"]
