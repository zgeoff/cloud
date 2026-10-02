# The atc-gateway image: atc's released binary on distroless, as the nonroot user.
# The build context holds the binary as ./atc-gateway, fetched and checked by
# scripts/fetch-atc-release.sh; nothing is downloaded inside the build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY --chmod=0555 atc-gateway /usr/local/bin/atc-gateway
# atc keeps its state under $HOME/.local/state/atc (the volume) and its sockets in
# $XDG_RUNTIME_DIR (an emptyDir).
ENV HOME=/home/nonroot XDG_RUNTIME_DIR=/run/atc
USER nonroot
EXPOSE 8414
ENTRYPOINT ["/usr/local/bin/atc-gateway"]
