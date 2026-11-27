// the service clients of the atc gateway's /mcp, each with the scopes its token holds; only
// boxxy's notice client is limited to messages, because its session runs on the owner's machine
export const atcGatewayServiceClients = ['boxxy', 'boxxy-notices', 'nixie'] as const;

export type ATCGatewayServiceClient = (typeof atcGatewayServiceClients)[number];

export const atcGatewayServiceClientScopes = {
  boxxy: ['read', 'spawn', 'message', 'kill'],
  'boxxy-notices': ['message'],
  nixie: ['read', 'spawn', 'message', 'kill'],
} as const satisfies Record<ATCGatewayServiceClient, readonly string[]>;
