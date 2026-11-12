# The boxxy server image: the server compiled to one binary by `bun build --compile` from
# deploy/boxxy/server.ts and the @boxxy/server package, and the live rules from deploy/boxxy/rules,
# on the distroless base that images/atc-gateway/versions.env pins, as the nonroot user. The build
# context holds the binary as ./boxxy-server and the rules as ./rules, which
# scripts/write-boxxy-image-context.sh writes; nothing is downloaded inside the build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY --chmod=0555 boxxy-server /usr/local/bin/boxxy-server
# read-only for every user; the folders keep their execute bit, so nonroot can open prompts/
COPY --chmod=a=rX rules/ /rules/
# the pod mounts the configuration file here from a ConfigMap, and the volume for the store at /data
ENV BOXXY_CONFIG=/etc/boxxy/config.json
USER nonroot
EXPOSE 8090 8091
ENTRYPOINT ["/usr/local/bin/boxxy-server"]
