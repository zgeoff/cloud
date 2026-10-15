// Bun's own WebSocket, taken before MSW replaces the global on listen. MSW's replacement drops
// Bun's `headers` option, which carries impd's token, so the stub impd's tests dial it with this.
export const NativeWebSocket = globalThis.WebSocket;
