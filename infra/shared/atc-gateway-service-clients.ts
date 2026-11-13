// the service clients of the atc gateway's /mcp, each with the scopes its token holds: the boxxy
// server's worker client reads, spawns, messages and kills sessions, and its notice client only
// sends messages, because the notice session runs on the owner's machine
export const atcGatewayServiceClients = ['boxxy', 'boxxy-notices'] as const;

export type ATCGatewayServiceClient = (typeof atcGatewayServiceClients)[number];

export const atcGatewayServiceClientScopes = {
  boxxy: ['read', 'spawn', 'message', 'kill'],
  'boxxy-notices': ['message'],
} as const satisfies Record<ATCGatewayServiceClient, readonly string[]>;
