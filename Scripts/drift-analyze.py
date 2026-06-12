#!/usr/bin/env python3
"""Analyze a drift-validation recording (see drift-validation.sh).

Finds 1.5 kHz ping events; each should appear as a pair: the digital copy
(process tap) followed by the acoustic copy (speaker -> mic). Reports the
pair separation over time; drift = separation change between the first and
last resolvable pairs. PRD §2 budget: < 200 ms over 60 minutes.

Usage: drift-analyze.py recording.wav
Exit: 0 if drift budget holds (or informational), 1 on failure to resolve.
"""
import math
import struct
import sys
import wave

TONE_HZ = 1500
WINDOW = 0.005       # Goertzel window (s)
EVENT_GAP = 5.0      # min seconds between ping events
PAIR_MAX_SEP = 1.0   # max seconds between digital and acoustic copies
BUDGET_MS_PER_HOUR = 200.0


def envelope(path):
    """5 ms-resolution amplitude envelope of the 1.5 kHz component."""
    with wave.open(path) as w:
        n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
        raw = w.readframes(n)
    samples = struct.unpack(f"<{n * ch}h", raw)
    mono = [samples[i * ch] / 32768 for i in range(n)]

    step = int(rate * WINDOW)
    k = 2 * math.pi * TONE_HZ / rate
    cos_k = math.cos(k)
    env = []
    for start in range(0, n - step, step):
        s1 = s2 = 0.0
        for i in range(start, start + step):
            s0 = mono[i] + 2 * cos_k * s1 - s2
            s2, s1 = s1, s0
        amp = math.sqrt(abs(s1 * s1 + s2 * s2 - 2 * cos_k * s1 * s2)) / step * 2
        env.append(amp)
    return env, WINDOW


def find_events(env, dt, threshold):
    """Rising-edge times where the envelope crosses the threshold."""
    events, last = [], -1e9
    for i, v in enumerate(env):
        t = i * dt
        if v > threshold and (i == 0 or env[i - 1] <= threshold):
            events.append((t, v))
    return events


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    env, dt = envelope(sys.argv[1])
    peak = max(env)
    if peak < 0.01:
        print(f"FAIL: no 1.5 kHz pings found (peak {peak:.4f}); "
              "check that clicks were playing and capture was not silent")
        return 1

    edges = find_events(env, dt, peak * 0.15)

    # Group edges into ping events (>EVENT_GAP apart), then pair the first
    # two edges within each event: digital copy, then acoustic copy.
    pairs = []
    i = 0
    while i < len(edges):
        event = [edges[i]]
        j = i + 1
        while j < len(edges) and edges[j][0] - edges[i][0] < EVENT_GAP:
            event.append(edges[j])
            j += 1
        if len(event) >= 2 and event[1][0] - event[0][0] <= PAIR_MAX_SEP:
            pairs.append((event[0][0], (event[1][0] - event[0][0]) * 1000))
        i = j

    if len(pairs) < 2:
        print(f"FAIL: only {len(pairs)} digital/acoustic pair(s) resolved; "
              "need at least 2 (is the mic hearing the speakers?)")
        return 1

    first_t, first_sep = pairs[0]
    last_t, last_sep = pairs[-1]
    span_min = (last_t - first_t) / 60
    drift_ms = last_sep - first_sep
    per_hour = drift_ms / span_min * 60 if span_min > 0 else float("inf")

    print(f"pairs resolved: {len(pairs)} over {span_min:.1f} min")
    print(f"separation: first {first_sep:.1f} ms @ {first_t:.0f}s, "
          f"last {last_sep:.1f} ms @ {last_t:.0f}s")
    print(f"drift: {drift_ms:+.1f} ms ({per_hour:+.1f} ms/hour)")
    verdict = abs(per_hour) < BUDGET_MS_PER_HOUR
    print(f"verdict: {'PASS' if verdict else 'FAIL'} "
          f"(budget {BUDGET_MS_PER_HOUR:.0f} ms/hour, PRD §2)")
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
