# The cloud-pepys image: the pepys host binary, ingest and the API compiled to one binary each, and
# the consumer modules, on the distroless base that images/atc-gateway/versions.env pins, as the
# nonroot user. scripts/write-pepys-image-context.sh writes the build context; nothing is
# downloaded or compiled inside the build. Each container names its own command.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY --chmod=0555 pepys-host /usr/local/bin/pepys-host
COPY --chmod=0555 pepys-ingest /usr/local/bin/pepys-ingest
COPY --chmod=0555 pepys-api /usr/local/bin/pepys-api
# consumers.json and <consumer>/<hash>.wasm, as `pepys build` wrote them
COPY --chmod=0444 modules/ /modules/
USER nonroot
