// the service clients of the atc gateway's /mcp, each with the scopes its token holds. nixie
// holds no spawn: a spawn can send any variable of the daemon's environment to a clone URL's host
export const atcGatewayServiceClients = ['boxxy', 'boxxy-notices', 'nixie'] as const;

export type ATCGatewayServiceClient = (typeof atcGatewayServiceClients)[number];

export const atcGatewayServiceClientScopes = {
  boxxy: ['read', 'spawn', 'message', 'kill'],
  'boxxy-notices': ['message'],
  nixie: ['read', 'message', 'kill'],
} as const satisfies Record<ATCGatewayServiceClient, readonly string[]>;
