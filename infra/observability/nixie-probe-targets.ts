// The nixie probes' target names, which their ServiceMonitors stamp on their series as the `target`
// label, and the alert rules select on (build-alert-rules.ts).
export const nixieProbeTargets = { turns: 'nixie-turns', status: 'nixie-status' } as const;
