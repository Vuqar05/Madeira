# Microphone

Games can use the iPhone's microphone for voice chat. Windows programs see one
capture device, **iOS Microphone**, through every Windows audio API that Wine
routes through mmdevapi: WASAPI (`IAudioCaptureClient`), DirectSound capture
and winmm `waveIn`.

## Using it

It is on by default. The first time a game listens, iOS asks for microphone
access, and the orange microphone indicator is on only while a game is
recording.

**While you play**, open the in-game menu and pick **Microphone: Off / On /
Headset**. It applies at once, also to a game that is already recording, and
the choice is kept for the next start.

| Mode | Audio session | Microphone |
|---|---|---|
| On (default) | PlayAndRecord, speaker by default, Bluetooth in A2DP | The phone's own. Bluetooth headphones keep full-quality sound. |
| Headset | as On, plus Bluetooth HFP | The headset's. Sound drops to telephone quality while a game is recording. |
| Off | Playback, as before this feature, when the session starts Off. A session that is already recording stays as it is. | Games still see the device, but it delivers silence and nothing is recording, so the indicator is off. |

The starting mode is **Settings › All settings › Audio › Microphone at start**
(`env.MADEIRA_MICROPHONE`: unset = On, `bluetooth` = Headset, `0` = Off).

If access was refused, games see no microphone and the menu switch is
disabled; turn it back on under iOS Settings › Privacy & Security › Microphone
› Madeira, then open Madeira again.

There is no echo cancellation. With the speaker, teammates can hear the game
through your microphone, so use headphones.

## How it works

- `app/Madeira/WineProcessBridge.m` sets the AVAudioSession category before
  Wine starts, and sets `MADEIRA_AUDIO_INPUT=1` unless access was refused.
  `madeira_mic_set_mode` (the menu's switch) runs on its own queue: it mutes the
  driver (`ios_audio_mic_set_active(0)`: the input queue is stopped and disposed
  first, because a category change under a running queue invalidates it),
  changes the audio session and the IO slice, and unmutes, which starts the queue
  again if a game is recording.
- Changing the audio session's *category* is slow and blocks the app's main
  thread (with Bluetooth it measured 2.5 to 6 s, and the game froze with its
  sound). So it is changed as little as possible: Off and On never change it
  once the session records; Headset adds Bluetooth HFP to the category once,
  and from then on On and Headset differ only in the preferred input (the
  built-in microphone or the headset's). If iOS keeps the output on HFP with
  the phone's microphone, the HFP option is dropped again. Every switch logs
  `[microphone] a -> b: input stopped N ms, session N ms; route in X, out Y`.
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
- While the microphone is off (or its queue would not start) the driver writes
  silence into each client's ring at the real-time rate, whenever the client
  asks for a packet, in the client's format (8-bit PCM silence is 0x80). A game
  sees a quiet microphone, not a stalled one.
- Log lines: `[ios_audio] mic ...` (capture clients, queue on/off, and an
  input peak every 10 s while a game listens: a peak of 0 means silence, often
  refused access), and the app's `microphone:` line at start.
- Host test: `tests/host/check-audio-capture.py`.
