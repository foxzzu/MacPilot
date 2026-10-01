#!/usr/bin/env python3
"""Synthesize a 42s ambient-electronic bed for the MacPilot promo video.

Structure (BPM 96, bar = 2.5s, 16.8 bars):
  bars 0-1   pad only
  bars 2-3   + bass + kick
  bars 4-5   + hats
  bars 6-13  + arp (full groove)
  bars 14+   strip back to pad, fade to silence by 42s
"""
import numpy as np, wave

SR = 44100
DUR = 51.6
BPM = 96.0
BEAT = 60.0 / BPM          # 0.625 s
BAR = 4 * BEAT             # 2.5 s
N = int(SR * DUR)
rng = np.random.default_rng(7)

def midi(m): return 440.0 * 2 ** ((m - 69) / 12)

L = np.zeros(N); R = np.zeros(N)

def add(buf, start, sig, gain=1.0):
    i0 = int(start * SR)
    if i0 >= N: return
    n = min(len(sig), N - i0)
    buf[i0:i0 + n] += sig[:n] * gain

def env_ar(n, a, r):
    e = np.ones(n)
    na, nr = int(a * SR), int(r * SR)
    if na > 0: e[:na] = np.linspace(0, 1, na)
    if nr > 0: e[-nr:] *= np.linspace(1, 0, nr)
    return e

def pad_note(f, dur, detune=0.0):
    t = np.arange(int(dur * SR)) / SR
    e = env_ar(len(t), 0.45, 0.55)
    f2 = f * (1 + detune)
    s = np.sin(2*np.pi*f2*t) + 0.32*np.sin(2*np.pi*2*f2*t) + 0.10*np.sin(2*np.pi*3*f2*t)
    return s * e

def pluck(f, dur, decay):
    t = np.arange(int(dur * SR)) / SR
    e = np.exp(-t / decay)
    s = np.sin(2*np.pi*f*t) + 0.18*np.sin(2*np.pi*2*f*t)
    return s * e

def kick():
    n = int(0.11 * SR); t = np.arange(n) / SR
    f = 45 + 90 * np.exp(-t * 30)
    ph = 2*np.pi*np.cumsum(f)/SR
    return np.sin(ph) * np.exp(-t * 26)

def hat():
    n = int(0.045 * SR); t = np.arange(n) / SR
    x = rng.standard_normal(n)
    x = np.diff(x, prepend=0)            # crude high-pass
    return x * np.exp(-t * 90) / (np.max(np.abs(x)) + 1e-9)

# chord progression (pad voicings, MIDI) + bass roots
PROG = [
    ([53, 57, 60, 64], 41),   # Fmaj7
    ([55, 59, 62, 64], 43),   # G6
    ([57, 60, 64, 67], 45),   # Am7
    ([60, 62, 64, 67], 48),   # C add9
]
nbars = int(np.ceil(DUR / BAR))
for bar in range(nbars):
    t0 = bar * BAR
    notes, root = PROG[bar % 4]
    for i, m in enumerate(notes):
        det = 0.0011 if i % 2 == 0 else -0.0011
        s = pad_note(midi(m), BAR + 0.4, det)
        add(L, t0, s, 0.052); add(R, t0, s, 0.052)
    # bass eighths (bars 2..13)
    if 2 <= bar < 18:
        for k in range(8):
            s = pluck(midi(root - 12), 0.30, 0.10)
            add(L, t0 + k*BEAT/2, s, 0.16); add(R, t0 + k*BEAT/2, s, 0.16)
    # kick four-on-floor (bars 2..13)
    if 2 <= bar < 18:
        for k in range(4):
            s = kick()
            add(L, t0 + k*BEAT, s, 0.50); add(R, t0 + k*BEAT, s, 0.50)
    # hats on offbeats (bars 4..13)
    if 4 <= bar < 18:
        for k in range(4):
            s = hat()
            add(L, t0 + k*BEAT + BEAT/2, s, 0.045)
            add(R, t0 + k*BEAT + BEAT/2, s, 0.060)
    # arp 16ths (bars 6..13), alternating pan
    if 6 <= bar < 18:
        pool = notes + [m + 12 for m in notes]
        seq = [0, 4, 1, 5, 2, 6, 3, 5]
        for k in range(16):
            m = pool[seq[k % len(seq)]]
            s = pluck(midi(m + 12), 0.16, 0.055)
            pan = 0.35 if k % 2 == 0 else 0.65
            add(L, t0 + k*BEAT/4, s, 0.070*(1-pan+0.5))
            add(R, t0 + k*BEAT/4, s, 0.070*(pan+0.5))

mix = np.stack([L, R], axis=1)
# master envelope: 0.3s fade-in, fade to 0 over the last 2.6s
t = np.arange(N) / SR
master = np.ones(N)
master[:int(0.3*SR)] = np.linspace(0, 1, int(0.3*SR))
fade = DUR - 2.6
master[t > fade] = np.clip(1 - (t[t > fade] - fade) / 2.6, 0, 1)
mix *= master[:, None]
mix = np.tanh(mix * 1.2)                       # gentle glue
mix *= 0.85 / (np.max(np.abs(mix)) + 1e-9)     # peak normalise

pcm = (mix * 32767).astype(np.int16)
with wave.open("/tmp/macpilot-promo-music.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print("wrote /tmp/macpilot-promo-music.wav", pcm.shape)
