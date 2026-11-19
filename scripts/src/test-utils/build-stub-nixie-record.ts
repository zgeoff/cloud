export function buildStubNixieRecord(sequence: number) {
  // a message record in the shape of nixie 0.3.0's contract
  return {
    kind: 'message',
    message: { text: `record ${sequence}` },
    recordedAt: new Date(Date.UTC(2026, 9, 12, 0, 0, sequence)).toISOString(),
    sequence,
    thread: 'conversation',
  };
}
