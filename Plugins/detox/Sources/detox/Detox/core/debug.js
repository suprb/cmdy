function debugEnabled() {
    if (globalThis.__DETOX_DEBUG__ === true) return true;
    try {
        return globalThis.localStorage?.getItem('detox.debug') === '1';
    } catch {
        return false;
    }
}

// Opt-in diagnostics for the audio graph and parser. Logging inside grain,
// sequencer, and modulation hot paths is expensive enough to disturb timing,
// so production sessions stay quiet unless explicitly enabled.
export function debugLog(...args) {
    if (debugEnabled()) console.debug(...args);
}
