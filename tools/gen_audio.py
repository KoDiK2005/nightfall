#!/usr/bin/env python3
"""
Procedural audio generator for NIGHTFALL.

Generates all sound assets from scratch (no external files) so the repo is
fully self-contained. Uses only the Python standard library.

Outputs (44.1 kHz, mono, 16-bit PCM WAV) into ../assets:
    heartbeat.wav  - a single lub-dub beat (game re-triggers it, faster as
                     the monster gets closer)
    scare.wav      - the jumpscare screech
    pickup.wav     - a soft chime for picking up a key
    step.wav       - a muffled footstep

Some assets (ambient.wav, roar.wav, creak.wav) are hand-picked/mixed custom
recordings, not generated here -- see the comments in main() below.
"""

import math
import os
import random
import struct
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets")


def write_wav(name, samples):
    """samples: list of floats in [-1, 1]."""
    path = os.path.join(OUT, name)
    peak = max((abs(s) for s in samples), default=1.0) or 1.0
    # gentle normalisation with headroom
    scale = 0.89 / peak
    frames = bytearray()
    for s in samples:
        v = int(max(-1.0, min(1.0, s * scale)) * 32767)
        frames += struct.pack("<h", v)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(frames))
    print(f"  wrote {name}  ({len(samples)/SR:.1f}s)")


def env_adsr(n, a, d, s_level, r):
    """Simple ADSR envelope of length n samples (a/d/r in samples).

    Robust to a/d/r exceeding n: writes are always bounds-checked.
    """
    out = [0.0] * n
    i = 0
    for k in range(a):
        if i >= n:
            return out
        out[i] = k / max(1, a); i += 1
    for k in range(d):
        if i >= n:
            return out
        out[i] = 1.0 + (s_level - 1.0) * (k / max(1, d)); i += 1
    sustain = max(0, n - a - d - r)
    for _ in range(sustain):
        if i >= n:
            return out
        out[i] = s_level; i += 1
    for k in range(r):
        if i >= n:
            return out
        out[i] = s_level * (1.0 - k / max(1, r)); i += 1
    return out


def make_ambient(seconds=24.0):
    n = int(seconds * SR)
    out = [0.0] * n
    # Detuned low drones forming an unsettling minor cluster.
    drones = [55.0, 58.27, 82.41, 110.0, 116.5]
    for f in drones:
        detune = f * (1.0 + random.uniform(-0.004, 0.004))
        phase = random.uniform(0, math.tau)
        lfo_r = random.uniform(0.05, 0.12)   # slow amplitude wobble
        lfo_p = random.uniform(0, math.tau)
        amp = random.uniform(0.10, 0.18)
        for i in range(n):
            t = i / SR
            trem = 0.75 + 0.25 * math.sin(lfo_r * math.tau * t + lfo_p)
            out[i] += amp * trem * math.sin(math.tau * detune * t + phase)
    # Breathing wind: filtered noise with a slow swell.
    prev = 0.0
    for i in range(n):
        t = i / SR
        white = random.uniform(-1, 1)
        prev = prev * 0.995 + white * 0.005      # low-pass -> rumble
        swell = 0.5 + 0.5 * math.sin(0.03 * math.tau * t)
        out[i] += prev * 3.0 * swell * 0.5
    # Occasional distant metallic hits for unease.
    for _ in range(int(seconds / 6)):
        pos = random.randint(0, n - SR)
        f = random.uniform(300, 900)
        length = int(SR * random.uniform(0.4, 0.9))
        e = env_adsr(length, int(0.002 * SR), int(0.05 * SR), 0.0, length)
        for k in range(length):
            if pos + k < n:
                out[pos + k] += 0.06 * e[k] * math.sin(math.tau * f * (k / SR))
    # Fade the loop seam so it repeats seamlessly.
    fade = int(0.5 * SR)
    for k in range(fade):
        g = k / fade
        out[k] *= g
        out[n - 1 - k] *= g
    return out


def make_heartbeat():
    beat_len = int(0.9 * SR)
    out = [0.0] * beat_len

    def thump(start, f0, dur, gain):
        length = int(dur * SR)
        for k in range(length):
            idx = start + k
            if 0 <= idx < beat_len:
                t = k / SR
                # pitch drops quickly -> chesty thud
                f = f0 * math.exp(-9 * t)
                env = math.exp(-14 * t)
                out[idx] += gain * env * math.sin(math.tau * f * t)

    thump(int(0.00 * SR), 90, 0.28, 1.0)   # lub
    thump(int(0.18 * SR), 70, 0.34, 0.8)   # dub
    return out


def make_scare(seconds=1.6):
    n = int(seconds * SR)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        # descending dissonant screech + harsh noise burst
        f1 = 1400 * math.exp(-1.4 * t)
        f2 = 1873 * math.exp(-1.1 * t)
        screech = math.sin(math.tau * f1 * t) + 0.7 * math.sin(math.tau * f2 * t)
        noise = random.uniform(-1, 1)
        attack = min(1.0, t / 0.01)
        decay = math.exp(-2.2 * t)
        out[i] = attack * decay * (0.6 * screech + 0.5 * noise)
    # sub-bass drop under it
    for i in range(n):
        t = i / SR
        out[i] += 0.6 * math.exp(-3 * t) * math.sin(math.tau * 45 * t)
    return out


def make_pickup():
    n = int(0.5 * SR)
    out = [0.0] * n
    for f, g in ((587.33, 0.5), (880.0, 0.4), (1174.66, 0.3)):
        for i in range(n):
            t = i / SR
            out[i] += g * math.exp(-5 * t) * math.sin(math.tau * f * t)
    return out


def make_step():
    """A dull, muffled footfall — a soft body thud, no sharp click."""
    n = int(0.17 * SR)
    out = [0.0] * n
    lp1 = lp2 = 0.0
    for i in range(n):
        t = i / SR
        white = random.uniform(-1, 1)
        # two-pole low-pass: strips the high 'clap' frequencies right out
        lp1 = lp1 * 0.93 + white * 0.07
        lp2 = lp2 * 0.93 + lp1 * 0.07
        attack = min(1.0, t / 0.014)          # ramped attack removes the click
        env = attack * math.exp(-15 * t)
        thud = math.exp(-32 * t) * math.sin(math.tau * 82 * t)  # low body
        out[i] = env * lp2 * 2.6 + 0.55 * thud
    return out


def make_whisper(seconds=3.2):
    """Breathy, band-limited, syllabic noise — a voice you can't quite hear."""
    n = int(seconds * SR)
    out = [0.0] * n
    # syllable gate: bursts of 'voice' separated by breath and silence
    env = [0.0] * n
    i = 0
    while i < n:
        g = random.choice([0.0, 0.0, 0.5, 0.85, 1.0])
        seg = int(SR * random.uniform(0.05, 0.20))
        for k in range(seg):
            if i + k < n:
                env[i + k] = g
        i += seg
    # smooth the gate so syllables glide instead of clicking
    sm = 0.0
    for i in range(n):
        sm += (env[i] - sm) * 0.004
        env[i] = sm
    lp = brt = 0.0
    for i in range(n):
        t = i / SR
        white = random.uniform(-1, 1)
        lp = lp * 0.90 + white * 0.10          # dark body
        brt = brt * 0.40 + white * 0.60        # bright breath
        band = brt - lp                        # emphasise the airy mid/highs
        trem = 0.75 + 0.25 * math.sin(math.tau * 5.5 * t)
        out[i] = band * env[i] * trem
    fade = int(0.2 * SR)                        # ease the ends
    for k in range(fade):
        g = k / fade
        out[k] *= g
        out[n - 1 - k] *= g
    return out


def make_roar(seconds=1.8):
    """The Stalker's roar as it spots you: a guttural, distorted bellow with
    a throat-growl tremolo and a rising screech overtone."""
    n = int(seconds * SR)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        vib = 1.0 + 0.05 * math.sin(math.tau * 6.0 * t)      # throat vibrato
        f0 = (78 + 34 * math.sin(math.tau * 0.5 * t)) * vib   # low fundamental
        s  = math.sin(math.tau * f0 * t)
        s += 0.6 * math.sin(math.tau * 2 * f0 * t)
        s += 0.4 * math.sin(math.tau * 3 * f0 * t)
        s += 0.3 * math.sin(math.tau * 4.5 * f0 * t)
        growl = random.uniform(-1, 1) * (0.5 + 0.5 * math.sin(math.tau * 33 * t))
        s += 0.7 * growl                                      # ragged growl
        screech = 0.35 * math.exp(-1.8 * t) * math.sin(math.tau * (500 + 700 * t) * t)
        a = (t / 0.06) if t < 0.06 else math.exp(-1.15 * (t - 0.06))
        out[i] = math.tanh(a * (s * 0.5 + screech) * 2.3)     # soft-clip -> harsher
    return out


def make_creak(seconds=0.8):
    """A wooden chest lid dragged open: stick-slip friction groan (a resonant
    body pulsed by a rising-then-falling grain rate) that slides down in pitch,
    finished by a dull settling clunk."""
    n = int(seconds * SR)
    out = [0.0] * n
    base = random.uniform(190.0, 250.0)
    lp = 0.0
    for i in range(n):
        t = i / SR
        f = base * (1.0 - 0.28 * (t / seconds))          # pitch sags as it swings
        grate = 20.0 + 20.0 * math.sin(math.tau * 0.7 * t)   # stick-slip grain rate
        grain = 0.45 + 0.55 * abs(math.sin(math.tau * grate * t))
        body = (math.sin(math.tau * f * t)
                + 0.5 * math.sin(math.tau * 2.02 * f * t)
                + 0.3 * math.sin(math.tau * 3.1 * f * t))
        white = random.uniform(-1, 1)
        lp = lp * 0.85 + white * 0.15                    # dry-wood filtered noise
        env = min(1.0, t / 0.02) * math.exp(-1.7 * t)
        out[i] = env * (0.7 * body * grain + 0.35 * lp * grain)
    clunk = int(0.13 * SR)                               # it thuds shut/settles
    for k in range(clunk):
        idx = n - clunk + k
        if 0 <= idx < n:
            tt = k / SR
            out[idx] += 0.55 * math.exp(-22 * tt) * math.sin(math.tau * 68 * tt)
    return out


def make_thud(seconds=0.35):
    """A thrown rock striking stone: a sharp filtered knock plus a couple of
    fading skitter-bounces, then quiet -- something to draw an ear toward."""
    n = int(seconds * SR)
    out = [0.0] * n
    lp = 0.0

    def knock(start_t, gain, freq):
        for i in range(n):
            t = i / SR - start_t
            if t < 0:
                continue
            out[i] += gain * math.exp(-40 * t) * math.sin(math.tau * freq * t)

    knock(0.0, 1.0, 145.0)                 # the main hit
    knock(0.05, 0.4, 210.0)                # a quick skitter bounce
    knock(0.11, 0.18, 260.0)               # a last tiny tick as it settles
    for i in range(n):
        t = i / SR
        white = random.uniform(-1, 1)
        lp = lp * 0.80 + white * 0.20      # short filtered crack on impact
        env = math.exp(-70 * t)
        out[i] += 0.5 * env * lp
    return out


def make_shrine(seconds=8.0):
    """A soft, sacred-but-wrong choral hum for the key shrines: a sustained
    open chord with a minor tinge, slow choral vibrato, and an airy breath
    layer. Loopable (the seam is cross-faded)."""
    n = int(seconds * SR)
    out = [0.0] * n
    voices = [130.81, 155.56, 196.00, 261.63]            # C3, Eb3, G3, C4 — minor tint
    for f in voices:
        detune = f * (1.0 + random.uniform(-0.003, 0.003))
        vph = random.uniform(0, math.tau)
        vlfo = random.uniform(0.10, 0.22)
        vrate = random.uniform(4.5, 5.5)                 # choral vibrato
        amp = random.uniform(0.08, 0.12)
        for i in range(n):
            t = i / SR
            vib = 1.0 + 0.004 * math.sin(math.tau * vrate * t + vph)
            trem = 0.80 + 0.20 * math.sin(vlfo * math.tau * t + vph)
            out[i] += amp * trem * math.sin(math.tau * detune * vib * t + vph)
    prev = 0.0                                           # airy breath undercurrent
    for i in range(n):
        white = random.uniform(-1, 1)
        prev = prev * 0.99 + white * 0.01
        out[i] += prev * 1.2 * 0.14
    fade = int(0.5 * SR)                                 # seamless loop seam
    for k in range(fade):
        g = k / fade
        out[k] *= g
        out[n - 1 - k] *= g
    return out


def make_growl(seconds=0.9):
    """A shorter, lower snarl the Stalker repeats while it hunts."""
    n = int(seconds * SR)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        f0 = 62 + 18 * math.sin(math.tau * 0.8 * t)
        s  = math.sin(math.tau * f0 * t) + 0.5 * math.sin(math.tau * 2 * f0 * t)
        growl = random.uniform(-1, 1) * (0.4 + 0.6 * math.sin(math.tau * 26 * t))
        s += 0.8 * growl
        a = (t / 0.05) if t < 0.05 else math.exp(-2.6 * (t - 0.05))
        out[i] = math.tanh(a * s * 1.8)
    return out


def main():
    random.seed(1917)
    os.makedirs(OUT, exist_ok=True)
    print("Generating audio assets...")
    # ambient.wav is now a hand-mixed custom recording (the game's main
    # ambient bed), not procedural -- do NOT regenerate it here or it would
    # clobber that asset. (make_ambient() is kept above as a fallback if you
    # want to restore the procedural drone.)
    write_wav("heartbeat.wav", make_heartbeat())
    write_wav("scare.wav", make_scare())
    write_wav("pickup.wav", make_pickup())
    write_wav("step.wav", make_step())
    write_wav("whisper.wav", make_whisper())
    # roar.wav is now a hand-picked custom recording (converted to WAV), not
    # procedural -- do NOT regenerate it here or it would clobber that asset.
    # (make_roar() is kept above as a fallback if you want to restore it.)
    write_wav("growl.wav", make_growl())
    # creak.wav (the chest-open sound) is also now a custom recording -- do
    # NOT regenerate it here. (make_creak() is kept above as a fallback.)
    write_wav("shrine.wav", make_shrine())
    write_wav("thud.wav", make_thud())
    print("Done.")


if __name__ == "__main__":
    main()
