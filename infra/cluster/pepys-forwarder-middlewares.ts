// Traefik's middlewares for the forwarders' tailnet route, which its file provider holds: the
// cluster has no Traefik CRDs, and an Ingress can name a middleware of another provider only.
const inFlight = 'pepys-forwarder-in-flight';
const slot = 'pepys-forwarder-slot';
const bodyLimit = 'pepys-forwarder-body-limit';

// the telemetry path's limit, which ingest also enforces
const maxBodyBytes = 4_194_304;

// Each request may hold a whole body in Traefik's memory, so the route takes 4 at once: 16 MiB at
// most. The limiter counts by a header that the first middleware sets and the client cannot change;
// counted by Host, a client could add a port to the Host header and get 4 more.
const maxInFlight = 4;
const slotHeader = 'X-Pepys-Forwarder-Slot';

export const pepysForwarderMiddlewares = {
  // the value of the Ingress annotation traefik.ingress.kubernetes.io/router.middlewares, in the
  // order Traefik runs them
  annotation: [slot, inFlight, bodyLimit].map((name) => `${name}@file`).join(','),

  // the file provider's dynamic configuration
  config: {
    http: {
      middlewares: {
        [slot]: { headers: { customRequestHeaders: { [slotHeader]: 'route' } } },
        [inFlight]: {
          inFlightReq: { amount: maxInFlight, sourceCriterion: { requestHeaderName: slotHeader } },
        },

        // the whole body in memory, so Traefik writes none of it to disk
        [bodyLimit]: {
          buffering: { maxRequestBodyBytes: maxBodyBytes, memRequestBodyBytes: maxBodyBytes },
        },
      },
    },
  },
} as const;
