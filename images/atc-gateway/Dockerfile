# The atc-gateway image: atc's released binary on distroless, as the nonroot user.
# The build context holds the binary as ./atc-gateway, fetched and checked by
# scripts/fetch-atc-release.sh; nothing is downloaded inside the build.
# GATEWAY_PORT is the gateway's port, from packages/topology/constants.json; the build fails
# without it.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG GATEWAY_PORT
COPY --chmod=0555 atc-gateway /usr/local/bin/atc-gateway
# atc keeps its state under $HOME/.local/state/atc (the volume) and its sockets in
# $XDG_RUNTIME_DIR (an emptyDir).
ENV HOME=/home/nonroot XDG_RUNTIME_DIR=/run/atc
USER nonroot
EXPOSE ${GATEWAY_PORT}
ENTRYPOINT ["/usr/local/bin/atc-gateway"]
