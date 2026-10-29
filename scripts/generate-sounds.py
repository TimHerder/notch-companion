#!/usr/bin/env python3
"""Generate the companion's original sound palette.

No samples, third-party assets, or Python dependencies are used. Each cue is
built from crisp mallet-like tones (fast attack, partials that decay faster
than the fundamental), tiny filtered-noise transients for tactile snap, and a
small shared room so cues feel physical rather than beeping. Timings follow
the eye animations in CompanionCharacter.swift. All cues are 48 kHz stereo
PCM16 with silent endpoints and headroom for the app's quiet default volume.
Run from any working directory to regenerate.
"""

from __future__ import annotations

import math
from pathlib import Path
import random
import struct
import wave

SAMPLE_RATE = 48_000
OUTPUT = Path(__file__).resolve().parents[1] / "Sources/NotchCompanion/Resources/Sounds"
MALLET = ((1.0, 1.0, 1.0), (2.0, 0.18, 1.8), (3.93, 0.08, 3.2))  # (ratio, amplitude, decay multiplier)
ROUND = ((1.0, 1.0, 1.0), (2.0, 0.14, 1.6))


def smoothstep(value: float) -> float:
    value = min(1.0, max(0.0, value))
    return value * value * (3.0 - 2.0 * value)


def pan_gains(pan: float) -> tuple[float, float]:
    return math.sqrt((1.0 - pan) / 2.0), math.sqrt((1.0 + pan) / 2.0)


def mix(channels, offset: int, index: int, value: float, gains) -> None:
    for channel, gain in zip(channels, gains):
        if 0 <= offset + index < len(channel):
            channel[offset + index] += value * gain


def tone(channels, start, duration, frequency, end_frequency=None, amp=1.0, *, pan=0.0,
         attack=0.002, decay=10.0, glide=0.05, partials=ROUND, vibrato=(0.0, 0.0)) -> None:
    """A struck tone. Pitch eases toward end_frequency over `glide` seconds."""
    end_frequency = end_frequency or frequency
    length = round(duration * SAMPLE_RATE)
    offset = round(start * SAMPLE_RATE)
    release = min(0.03, duration * 0.3)
    gains = pan_gains(pan)
    phases = [0.0] * len(partials)
    for index in range(length):
        t = index / SAMPLE_RATE
        eased = 1.0 - (1.0 - min(1.0, t / glide)) ** 3
        pitch = frequency + (end_frequency - frequency) * eased
        pitch *= 1.0 + vibrato[1] * math.sin(math.tau * vibrato[0] * t)
        shape = smoothstep(t / attack) * smoothstep((duration - t - 1.0 / SAMPLE_RATE) / release)
        value = 0.0
        for k, (ratio, level, decay_scale) in enumerate(partials):
            phases[k] += math.tau * pitch * ratio / SAMPLE_RATE
            value += level * math.exp(-decay * decay_scale * t) * math.sin(phases[k])
        mix(channels, offset, index, amp * shape * value, gains)


def noise(channels, start, duration, center, end_center=None, amp=1.0, *, q=1.2, pan=0.0,
          attack=0.0008, decay=200.0, seed=1) -> None:
    """Band-passed noise (state-variable filter) for clicks, crunches, and air."""
    end_center = end_center or center
    rng = random.Random(seed)
    length = round(duration * SAMPLE_RATE)
    offset = round(start * SAMPLE_RATE)
    release = min(0.01, duration * 0.3)
    gains = pan_gains(pan)
    low = band = 0.0
    damping = 1.0 / q
    for index in range(length):
        t = index / SAMPLE_RATE
        cutoff = center * (end_center / center) ** (index / max(1, length - 1))
        f = 2.0 * math.sin(math.pi * cutoff / SAMPLE_RATE)
        high = rng.uniform(-1.0, 1.0) - low - damping * band
        band += f * high
        low += f * band
        shape = smoothstep(t / attack) * smoothstep((duration - t - 1.0 / SAMPLE_RATE) / release)
        mix(channels, offset, index, amp * shape * math.exp(-decay * t) * band, gains)


def crunch(channels, start, amp, pan, seed) -> None:
    """A bite: a few ultra-short ticks read as texture rather than one click."""
    for step, (delay, level) in enumerate(((0.0, 1.0), (0.009, 0.6), (0.021, 0.35))):
        noise(channels, start + delay, 0.018, 2600 + 500 * step, amp=amp * level, q=1.6, pan=pan,
              decay=160, seed=seed + step)


def room(channels, wet: float) -> None:
    """Freeverb-style small room: four damped combs and two allpasses per side."""
    source = [(left + right) * 0.5 for left, right in zip(*channels)]
    for side, channel in enumerate(channels):
        spread = 25 * side
        combs = [[[0.0] * (size + spread), 0, 0.0] for size in (1214, 1293, 1390, 1475)]
        allpasses = [[[0.0] * (size + spread), 0] for size in (605, 480)]
        for index, value in enumerate(source):
            out = 0.0
            for comb in combs:
                buffer, position, filtered = comb
                delayed = buffer[position]
                filtered = delayed * 0.7 + filtered * 0.3
                buffer[position] = value * 0.12 + filtered * 0.74
                comb[1] = (position + 1) % len(buffer)
                comb[2] = filtered
                out += delayed
            for allpass in allpasses:
                buffer, position = allpass
                delayed = buffer[position]
                buffer[position] = out + delayed * 0.5
                allpass[1] = (position + 1) % len(buffer)
                out = delayed - out
            channel[index] += wet * out


def render(name: str, duration: float, build, peak_target: float, wet: float) -> dict:
    frames = round(duration * SAMPLE_RATE)
    channels = [[0.0] * frames, [0.0] * frames]
    build(channels)
    room(channels, wet)
    fade = round(0.012 * SAMPLE_RATE)
    for index in range(frames - fade, frames):
        for channel in channels:
            channel[index] *= smoothstep((frames - 1 - index) / fade)
    peak = max(abs(value) for channel in channels for value in channel)
    multiplier = peak_target / peak if peak else 1.0
    pcm = [
        max(-32767, min(32767, round(channels[channel][frame] * multiplier * 32767)))
        for frame in range(frames)
        for channel in range(2)
    ]
    assert pcm[0:2] == [0, 0] and pcm[-2:] == [0, 0], "Cue must begin and end at silence"
    assert max(abs(value) for value in pcm) < 32767, "Cue must not clip"
    with wave.open(str(OUTPUT / f"{name}.wav"), "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(SAMPLE_RATE)
        audio.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))
    rms = math.sqrt(sum((value / 32768.0) ** 2 for value in pcm) / len(pcm))
    peak_db = 20.0 * math.log10(max(abs(value) for value in pcm) / 32768.0)
    return {"peak_dbfs": peak_db, "rms_dbfs": 20.0 * math.log10(rms)}


def expand(c):
    # Soft tick, a rising bloop as the notch opens, and a small glint on arrival.
    noise(c, 0, 0.012, 4500, amp=0.22, decay=300)
    tone(c, 0.002, 0.24, 280, 560, glide=0.09, decay=14, pan=-0.08)
    tone(c, 0.06, 0.16, 1120, 1180, 0.14, decay=22, pan=0.12, partials=((1.0, 1.0, 1.0),))


def collapse(c):
    # One soft voice and no impact (the ease-out close has none): a pure B4 -> E4 fall with a
    # gentle start. It rings out fully; cutting it short made the room flutter like a gated snare.
    tone(c, 0, 0.6, 493.88, 329.63, attack=0.01, glide=0.16, decay=12, partials=((1.0, 1.0, 1.0),))


def attach(c):
    # Two bites on the chomp frames (0 s and 0.24 s), a gulp, then a sparkle with the smile.
    tone(c, 0, 0.09, 300, 170, glide=0.04, decay=40, pan=-0.1, partials=((1.0, 1.0, 1.0), (2.0, 0.3, 1.5)))
    crunch(c, 0, 0.55, -0.1, seed=10)
    tone(c, 0.24, 0.09, 330, 185, glide=0.04, decay=40, pan=0.1, partials=((1.0, 1.0, 1.0), (2.0, 0.3, 1.5)))
    crunch(c, 0.24, 0.65, 0.1, seed=20)
    tone(c, 0.37, 0.12, 360, 720, 0.7, glide=0.06, decay=22)
    tone(c, 0.43, 0.3, 1318.51, amp=0.16, decay=9, pan=-0.12, partials=MALLET)
    tone(c, 0.49, 0.3, 1975.53, amp=0.12, decay=10, pan=0.14, partials=MALLET)


def send(c):
    # Air sweeps up, then a bright pluck lifts away.
    noise(c, 0, 0.13, 700, 3800, 0.9, q=0.9, attack=0.03, decay=10, pan=-0.1, seed=3)
    tone(c, 0.045, 0.2, 620, 930, glide=0.035, decay=16, pan=0.08, partials=MALLET)
    tone(c, 0.085, 0.12, 1860, amp=0.1, decay=30, pan=0.15, partials=((1.0, 1.0, 1.0),))


def complete(c):
    # A struck rising fifth with a little shimmer; brief enough to hear often.
    noise(c, 0, 0.006, 5000, amp=0.12, decay=400, seed=4)
    tone(c, 0, 0.55, 659.25, amp=0.8, attack=0.0015, decay=6, pan=-0.08, partials=MALLET)
    tone(c, 0.1, 0.7, 987.77, attack=0.0015, decay=5, pan=0.1, partials=MALLET)
    tone(c, 0.1, 0.35, 1975.53, amp=0.07, decay=12, pan=-0.15, partials=((1.0, 1.0, 1.0),))


def attention(c):
    # "Hm?" — a curious pair that bends upward, peaking with the eyes' hop.
    tone(c, 0, 0.16, 783.99, amp=0.75, decay=14)
    tone(c, 0.13, 0.28, 1046.5, 1174.66, glide=0.08, decay=8, pan=0.08)


def failure(c):
    # A gentle falling minor third that wobbles with the worried shake.
    wobble = (6.5, 0.012)
    tone(c, 0, 0.22, 415.3, amp=0.9, attack=0.003, decay=9, vibrato=wobble,
         partials=((1.0, 1.0, 1.0), (2.0, 0.1, 1.5), (3.0, 0.06, 2.0)))
    tone(c, 0.17, 0.38, 349.23, 330, glide=0.25, attack=0.003, decay=6, vibrato=wobble,
         partials=((1.0, 1.0, 1.0), (2.0, 0.1, 1.5), (3.0, 0.06, 2.0)))


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    palette = {  # name: (duration, builder, peak target, room)
        "expand": (0.42, expand, 0.23, 0.14),
        "collapse": (0.65, collapse, 0.148, 0.05),
        "attach": (0.85, attach, 0.44, 0.12),
        "send": (0.38, send, 0.23, 0.12),
        "complete": (1.0, complete, 0.28, 0.18),
        "attention": (0.6, attention, 0.22, 0.14),
        "failure": (0.7, failure, 0.18, 0.10),
    }
    print("Original cue QA: stereo PCM16 / 48,000 Hz / silent endpoints / no clipping")
    print("cue        duration    peak dBFS    RMS dBFS")
    for name, (duration, build, peak_target, wet) in palette.items():
        result = render(name, duration, build, peak_target, wet)
        print(f"{name:10} {duration:6.3f}s {result['peak_dbfs']:11.2f} {result['rms_dbfs']:11.2f}")


if __name__ == "__main__":
    main()
