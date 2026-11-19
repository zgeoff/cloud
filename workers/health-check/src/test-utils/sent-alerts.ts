interface SentAlert {
  readonly contentType: string | null;
  readonly body: string;
}

export const sentAlerts: SentAlert[] = [];
