# SMS Audio Handoff - 2026-05-16

## Current status

The Master System emulator is now using a native PipeWire PCM helper by default for PSG audio. This is much better than the earlier `Gosu::Sample` chunk path, but audio still has a small residual stutter/near-underrun feel in some cases.

The current best-sounding path is:

```sh
bundle exec ruby bin/crystal
```

`PsgPlayer` defaults to `ASTRAL_PSG_MODE=pipe`, which builds and spawns `tmp/pipewire_pcm_sink` from `native/pipewire_pcm_sink.c`.

## What changed

- Added `native/pipewire_pcm_sink.c`, a small native PipeWire playback helper.
- The helper reads signed 16-bit mono PCM from stdin into a local ringbuffer.
- PipeWire consumes audio from the helper ringbuffer in its process callback.
- Ruby no longer uses `pw-cat` by default.
- `pw-cat` and `aplay` are still fallback sinks.
- Old Gosu audio modes are still available for comparison:

```sh
ASTRAL_PSG_MODE=chunk bundle exec ruby bin/crystal
ASTRAL_PSG_MODE=loop bundle exec ruby bin/crystal
```

## Timing changes

The previous fixed `735` samples/frame underfed the audio sink. `PsgPlayer#samples_for_frame` now uses a fractional accumulator based on:

- `SAMPLE_RATE = 44100`
- `FRAME_CYCLES = 59736`
- `SmsEmulator::PSG::CLOCK = 3579545.0`

There is a small configurable oversupply:

```sh
ASTRAL_AUDIO_OVERSUPPLY=1.0005
```

Useful values to test:

```sh
ASTRAL_AUDIO_OVERSUPPLY=1.000 bundle exec ruby bin/crystal
ASTRAL_AUDIO_OVERSUPPLY=1.0005 bundle exec ruby bin/crystal
ASTRAL_AUDIO_OVERSUPPLY=1.001 bundle exec ruby bin/crystal
```

Default is currently `1.0005`. In quick sampling it produced counts like:

```text
[736, 736, 736, 737, 736, 736, ...]
```

## PSG render state

`SmsEmulator::PSG#render_frame_samples` replays PSG writes at their frame cycle and then restores the renderer state back into the main PSG instance. This prevents oscillator/noise phase from restarting at frame boundaries.

This was important because the user described the audio as correct but slightly repeating/staking at frame edges.

## ROM loader side fix

Rampage did not boot because `/home/nichlas/roms/rampage.sms` has a 512-byte copier header:

- file size: `262656`
- actual ROM starts at offset `0x200`

`SmsEmulator::Memory#load_rom` now strips 512-byte copier headers when ROM size is `0x4000n + 512`.

## Current verification

Last full suite:

```sh
bundle exec rspec
```

Result:

```text
63 examples, 0 failures
```

Native helper checks performed:

```sh
cc native/pipewire_pcm_sink.c -o /tmp/pipewire_pcm_sink_test $(pkg-config --cflags --libs libpipewire-0.3) -pthread
bundle exec ruby -Ilib -e 'require "gosu"; require "astral_verse/audio/psg_player"; require "sms_emulator/audio/psg"; psg=SmsEmulator::PSG.new; player=AstralVerse::PsgPlayer.new(psg); player.stop; puts File.executable?("tmp/pipewire_pcm_sink") ? "native_sink_ready" : "native_sink_missing"'
```

## Known issue

Audio is close but not finished. The remaining symptom is a tiny stutter/repetition feeling despite the tone/timing being mostly correct.

Do not go back to masking underruns with decay/prebuffer tricks. That made the audio sound like it had hiccups.

The best next step is to decouple audio production from UI update cadence:

1. Add a dedicated Ruby audio producer thread, or move PSG sample production into the native helper.
2. Feed smaller, steadier audio blocks into the native ringbuffer.
3. Add ringbuffer telemetry from the native helper: queued samples, underrun count, dropped samples.
4. Use that telemetry to tune `ASTRAL_AUDIO_OVERSUPPLY` dynamically rather than hardcoding a guess.

## Files touched

- `lib/astral_verse/audio/psg_player.rb`
- `lib/sms_emulator/audio/psg.rb`
- `lib/sms_emulator/emulator.rb`
- `lib/sms_emulator/memory.rb`
- `native/pipewire_pcm_sink.c`
- `spec/sms_memory_vdp_spec.rb`
- `spec/sms_psg_spec.rb`
