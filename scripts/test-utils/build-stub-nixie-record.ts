// A record of nixie's conversation thread in the shape of nixie 0.3.0's contract: a message
// record, recorded one second per sequence after a fixed start
export function buildStubNixieRecord(sequence: number) {
  return {
    kind: 'message',
    message: { text: `record ${sequence}` },
    recordedAt: new Date(Date.UTC(2026, 9, 12, 0, 0, sequence)).toISOString(),
    sequence,
    thread: 'conversation',
  };
}
