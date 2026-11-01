# Microphone

Games can use the iPhone's microphone for voice chat. Windows programs see one
capture device, **iOS Microphone**, through every Windows audio API that Wine
routes through mmdevapi: WASAPI (`IAudioCaptureClient`), DirectSound capture
and winmm `waveIn`.

## Using it

It is on by default. The first time a game listens, iOS asks for microphone
access, and the orange microphone indicator is on only while a game is
recording. To turn it off, or to record through a Bluetooth headset, use
**Settings › All settings › Audio › Microphone** (`env.MADEIRA_MICROPHONE` in
`madeira.cfg`), then restart Madeira:

| Value | Session | Microphone |
|---|---|---|
| unset (default) | PlayAndRecord, speaker by default, Bluetooth in A2DP | The phone's own. Bluetooth headphones keep full-quality sound. |
| `bluetooth` | as above, plus Bluetooth HFP | The headset's. Sound drops to telephone quality while a game is recording. |
| `0` | Playback, as before this feature | None is listed. |

If access was refused, games see no microphone; turn it back on under
iOS Settings › Privacy & Security › Microphone › Madeira.

There is no echo cancellation. With the speaker, teammates can hear the game
through your microphone, so use headphones.

## How it works

- `app/Madeira/WineProcessBridge.m` sets the AVAudioSession category before
  Wine starts, and sets `MADEIRA_AUDIO_INPUT=1` when the session can record
  (input available, access not refused).
- `build/ntdll-unix/audio_null_ios.c` then lists the capture endpoint. The
  microphone is read through an AudioQueue (16-bit mono, 48 kHz), not through
  the RemoteIO output unit: enabling input on RemoteIO means
  re-initialising a unit that is kept for the process lifetime (ml1026). The
  queue is created when the first capture client starts and disposed when the
  last one stops.
- The queue's callback resamples (linear) to each client's rate, copies the
  mono signal to all of its channels and converts it to its format (float32,
  8/16/24/32-bit PCM) into the client's ring. `get_capture_buffer` hands out
  one engine period per packet from the stream's scratch buffer, which is in
  the guest window for 32-bit games. A full ring drops new frames and marks the
  next packet `AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY`.
- Log lines: `[ios_audio] mic ...` (capture clients, queue on/off, and an
  input peak every 10 s while a game listens: a peak of 0 means silence, often
  refused access), and the app's `microphone:` line at start.
- Host test: `tests/host/check-audio-capture.py`.
