// Reading without input still counts for this long after the last real interaction.
export const IDLE_LIMIT_MS = 120000;
// Sampling gaps longer than this are suspended pages or computer sleep.
const MAX_SAMPLE_GAP_MS = 10000;
// Stretches closer than this are one continuous visit interval.
const INTERVAL_JOIN_MS = 2000;
export const MAX_INTERVALS = 500;

export class ReviewTime {
  constructor(send, now = () => performance.now(), clientId = crypto.randomUUID(), wall = () => Date.now()) {
    this.send = send;
    this.now = now;
    this.wall = wall;
    this.clientId = clientId;
    this.last = now();
    this.lastInput = -Infinity;
    this.active = false;
    this.scope = 'full';
    this.elapsed = new Map();
    this.intervals = new Map();
    this.saved = new Map();
  }

  // Trusted pointer, wheel, touch or key input. Focus alone does not prove a person is present:
  // agents can load a background browser tab that reports focus without anyone looking at it.
  input() {this.lastInput = this.now();}

  update(visible, focused, scope, paused = false) {
    const now = this.now(), delta = now - this.last;
    // shortcut: stalls above 10s are excluded alongside sleep; use host idle signals if stall attribution is needed.
    if (this.active && delta >= 0 && delta <= MAX_SAMPLE_GAP_MS) {
      const counted = Math.min(delta, Math.max(0, this.lastInput + IDLE_LIMIT_MS - this.last));
      if (counted > 0) {
        this.elapsed.set(this.scope, (this.elapsed.get(this.scope) || 0) + counted);
        const end = Math.round(this.wall() - (delta - counted));
        this.record(this.scope, Math.round(end - counted), end);
      }
    }
    this.last = now;
    this.active = visible && focused && !paused;
    this.scope = scope;
  }

  record(scope, start, end) {
    const intervals = this.intervals.get(scope) || [];
    const previous = intervals.at(-1);
    if (previous && start - previous[1] <= INTERVAL_JOIN_MS) previous[1] = Math.max(previous[1], end);
    else intervals.push([start, end]);
    // Keep the newest stretches; the counter remains the source of truth for totals.
    if (intervals.length > MAX_INTERVALS) intervals.splice(0, intervals.length - MAX_INTERVALS);
    this.intervals.set(scope, intervals);
  }

  async flush() {
    await Promise.all([...this.elapsed].map(async ([scope, elapsed]) => {
      const elapsedMs = Math.floor(elapsed);
      if (elapsedMs <= (this.saved.get(scope) || 0)) return;
      try {
        await this.send({clientId: this.clientId, scope, elapsedMs, intervals: (this.intervals.get(scope) || []).map(([start, end]) => [start, end])});
        this.saved.set(scope, Math.max(this.saved.get(scope) || 0, elapsedMs));
      } catch { /* Retry cumulative counters at the next checkpoint without disrupting review. */ }
    }));
  }
}

export function formatReviewTime(ms) {
  const seconds = Math.floor(ms / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
