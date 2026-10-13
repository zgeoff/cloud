interface SentAlert {
  readonly contentType: string | null;
  readonly body: string;
}

// Each post the alert webhook received, in order; the preload empties it after each test
export const sentAlerts: SentAlert[] = [];
