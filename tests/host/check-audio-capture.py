#!/usr/bin/env python3
"""Microphone capture of the iOS audio driver (build/ntdll-unix/audio_null_ios.c); no Wine runs.

Compiles the production struct ios_stream, ios_cap_store and ios_cap_feed against stubs, then
checks the path from the AudioQueue's 16-bit mono samples into a capture client's ring: a
48 kHz client gets the samples unchanged (one sample late, the resampler's carry), a 16 kHz
client gets every third, a 44.1 kHz client gets the right number of frames over a second with
no gap at buffer boundaries, every channel of a stereo client carries the microphone, each
sample format (float32, 8/16/24/32-bit PCM) is written at full scale, a full ring drops the new
frames and counts them, and a client that is not started gets nothing.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/audio_null_ios.c").read_text()

def cut(start, end):
    a = src.index(start)
    return src[a:src.index(end, a)]

stream = cut("struct ios_stream {", "/* ml739: one stream object per client")
cap_dev = cut("struct ios_capture_device {", "static struct ios_capture_device g_cap;")
store = cut("static void ios_cap_store(", "/* Append n microphone samples")
feed = cut("static void ios_cap_feed(", "/* The queue's thread.")
silence = cut("static int ios_cap_silent(", "/* The app's microphone switch")

harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <math.h>
typedef unsigned char BYTE; typedef uint16_t WORD; typedef uint32_t UINT32, DWORD, UInt32;
typedef void *HANDLE; typedef void *AudioQueueRef;
static uint64_t fake_ns; static uint64_t mach_absolute_time(void) { return fake_ns; }
static uint64_t mach_to_ns(uint64_t m) { return m; }
""" + stream + cap_dev + "static struct ios_capture_device g_cap;\n" + store + feed + silence + r"""
static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL " __VA_ARGS__); printf("\n"); fails++; } } while (0)

static BYTE ring[1 << 20];

static void client(struct ios_stream *s, UINT32 rate, UINT32 ch, int bits, int is_float, UINT32 frames)
{
    memset(s, 0, sizeof(*s));
    memset(ring, 0xAA, sizeof(ring));
    s->capture = 1; s->started = 1; s->mixable = 1;
    s->sample_rate = rate; s->channels = ch; s->sample_bits = bits; s->is_float = is_float;
    s->frame_bytes = ch * (UINT32)bits / 8; s->buffer_frames = frames; s->ring = ring;
}

static int16_t ramp(unsigned k) { return (int16_t)((k * 37u) % 20000u) - 10000; }

static int16_t ring16(struct ios_stream *s, uint64_t f, UINT32 c)
{
    int16_t v; memcpy(&v, s->ring + (size_t)(f % s->buffer_frames) * s->frame_bytes + c * 2, 2); return v;
}

int main(void)
{
    struct ios_stream s;
    int16_t in[4800];
    unsigned k, f;

    for (k = 0; k < 4800; k++) in[k] = ramp(k);

    /* same rate: the input, one sample late (sample 0 is the carry, silence at start) */
    client(&s, 48000, 1, 16, 0, 9600);
    ios_cap_feed(&s, in, 480, 48000);
    ios_cap_feed(&s, in + 480, 480, 48000);
    CHECK(atomic_load(&s.write_pos) == 960, "48k: %llu frames for 960 in", (unsigned long long)atomic_load(&s.write_pos));
    CHECK(ring16(&s, 0, 0) == 0, "48k: first frame is the zero carry");
    for (f = 1; f < 960; f++)
        if (abs(ring16(&s, f, 0) - in[f - 1]) > 1) { CHECK(0, "48k frame %u: %d want %d", f, ring16(&s, f, 0), in[f - 1]); break; }

    /* 16 kHz: a third of the frames, each an input sample */
    client(&s, 16000, 1, 16, 0, 9600);
    for (k = 0; k < 10; k++) ios_cap_feed(&s, in + k * 480, 480, 48000);
    CHECK(atomic_load(&s.write_pos) == 1600, "16k: %llu frames for 4800 in", (unsigned long long)atomic_load(&s.write_pos));
    for (f = 1; f < 1600; f++)
        if (abs(ring16(&s, f, 0) - in[f * 3 - 1]) > 1) { CHECK(0, "16k frame %u: %d want %d", f, ring16(&s, f, 0), in[f * 3 - 1]); break; }

    /* 44.1 kHz stereo over one second of 10 ms buffers: 44100 frames (+-1), both channels
     * equal, and no jump at a buffer boundary larger than the ramp's own slope */
    client(&s, 44100, 2, 16, 0, 48000);
    {
        int16_t sec[48000];
        int worst = 0;
        for (k = 0; k < 48000; k++) sec[k] = (int16_t)(k % 2000) * 10 - 10000;
        for (k = 0; k < 100; k++) ios_cap_feed(&s, sec + k * 480, 480, 48000);
        CHECK(atomic_load(&s.write_pos) >= 44099 && atomic_load(&s.write_pos) <= 44101,
              "44.1k: %llu frames in a second", (unsigned long long)atomic_load(&s.write_pos));
        for (f = 1; f < 44000; f++) {
            int d = ring16(&s, f, 0) - ring16(&s, f - 1, 0);
            CHECK(ring16(&s, f, 0) == ring16(&s, f, 1), "44.1k frame %u: channels differ", f);
            if (d > 0 && d > worst) worst = d;
            if (ring16(&s, f, 0) != ring16(&s, f, 1)) break;
        }
        CHECK(worst <= 12, "44.1k: largest step %d (ramp slope ~10.9)", worst);
    }

    /* formats, at full scale: +1.0 (32767) and -1.0 (-32768) */
    {
        int16_t hi[3] = { 32767, 32767, -32768 };
        float fv; int16_t i16; int32_t i32;
        client(&s, 48000, 1, 32, 1, 16);
        ios_cap_feed(&s, hi, 3, 48000);
        memcpy(&fv, s.ring + 4, 4);  CHECK(fabsf(fv - 32767.0f / 32768.0f) < 1e-6f, "float32 +: %f", fv);
        memcpy(&fv, s.ring + 8, 4);  CHECK(fabsf(fv - 32767.0f / 32768.0f) < 1e-6f, "float32 second: %f", fv);
        client(&s, 48000, 1, 16, 0, 16);
        hi[2] = -32768; ios_cap_feed(&s, hi, 3, 48000);
        memcpy(&i16, s.ring + 2, 2); CHECK(i16 >= 32766, "pcm16 +: %d", i16);
        client(&s, 48000, 1, 8, 0, 16);
        ios_cap_feed(&s, hi, 3, 48000);
        CHECK(s.ring[0] == 128, "pcm8 silence: %u", s.ring[0]);
        CHECK(s.ring[1] >= 254, "pcm8 +: %u", s.ring[1]);
        client(&s, 48000, 1, 24, 0, 16);
        ios_cap_feed(&s, hi, 3, 48000);
        i32 = s.ring[3] | s.ring[4] << 8 | (int8_t)s.ring[5] << 16;
        CHECK(i32 > 8388000, "pcm24 +: %d", i32);
        client(&s, 48000, 1, 32, 0, 16);
        { int16_t lo[2] = { -32768, -32768 }; ios_cap_feed(&s, lo, 2, 48000); }
        memcpy(&i32, s.ring + 4, 4); CHECK(i32 <= -2147483000, "pcm32 -: %d", i32);
    }

    /* a full ring drops the newest frames and counts them; the client reading frees room */
    client(&s, 48000, 1, 16, 0, 600);
    ios_cap_feed(&s, in, 480, 48000);
    ios_cap_feed(&s, in + 480, 480, 48000);
    CHECK(atomic_load(&s.write_pos) == 600, "full: wrote %llu of a 600-frame ring", (unsigned long long)atomic_load(&s.write_pos));
    CHECK(atomic_load(&s.cap_dropped) == 360, "full: dropped %u, want 360", atomic_load(&s.cap_dropped));
    atomic_store(&s.play_pos, 480);
    ios_cap_feed(&s, in + 960, 480, 48000);
    CHECK(atomic_load(&s.write_pos) == 1080, "after read: write_pos %llu", (unsigned long long)atomic_load(&s.write_pos));

    /* not started: nothing */
    client(&s, 48000, 1, 16, 0, 600);
    s.started = 0;
    ios_cap_feed(&s, in, 480, 48000);
    CHECK(atomic_load(&s.write_pos) == 0, "stopped client got %llu frames", (unsigned long long)atomic_load(&s.write_pos));

    /* muted: silence in real time, at the client's rate and in its format */
    client(&s, 16000, 2, 16, 0, 16000);
    atomic_store(&g_cap.muted, 1);
    fake_ns = 5000000000ull;
    ios_cap_silence(&s);                                   /* first call only sets the clock */
    CHECK(atomic_load(&s.write_pos) == 0, "muted: first call wrote %llu", (unsigned long long)atomic_load(&s.write_pos));
    fake_ns += 10000000ull;                                /* 10 ms -> 160 frames */
    ios_cap_silence(&s);
    CHECK(atomic_load(&s.write_pos) == 160, "muted: 10 ms gave %llu frames", (unsigned long long)atomic_load(&s.write_pos));
    /* polled every 0.625 ms (10 frames): no time is lost to rounding, 100 polls = 1000 frames */
    for (k = 0; k < 100; k++) { fake_ns += 625000; ios_cap_silence(&s); }
    CHECK(atomic_load(&s.write_pos) == 1160, "muted: polling gave %llu frames, want 1160", (unsigned long long)atomic_load(&s.write_pos));
    for (f = 0; f < atomic_load(&s.write_pos); f++)
        if (ring16(&s, f, 0) != 0 || ring16(&s, f, 1) != 0) { CHECK(0, "muted frame %u not silent", f); break; }
    { uint64_t w = atomic_load(&s.write_pos);
      fake_ns += 5000000000ull;                            /* the client stops reading for 5 s */
      ios_cap_silence(&s);
      CHECK(atomic_load(&s.write_pos) == w + 14840 && atomic_load(&s.cap_dropped) == 80000 - 14840,
            "muted overrun: write_pos %llu dropped %u", (unsigned long long)atomic_load(&s.write_pos), atomic_load(&s.cap_dropped)); }
    client(&s, 48000, 1, 8, 0, 480);                       /* 8-bit PCM silence is 0x80 */
    atomic_store(&g_cap.muted, 1);
    fake_ns = 1; ios_cap_silence(&s); fake_ns += 1000000; ios_cap_silence(&s);
    CHECK(atomic_load(&s.write_pos) == 48 && s.ring[0] == 0x80 && s.ring[47] == 0x80, "muted 8-bit: %llu frames, first byte %u",
          (unsigned long long)atomic_load(&s.write_pos), s.ring[0]);
    atomic_store(&g_cap.in_cb, 1);                         /* the queue callback still inside: wait */
    { uint64_t w = atomic_load(&s.write_pos); fake_ns += 1000000; ios_cap_silence(&s);
      CHECK(atomic_load(&s.write_pos) == w, "muted: wrote while the callback was in flight"); }
    atomic_store(&g_cap.in_cb, 0);
    atomic_store(&g_cap.muted, 0);                         /* unmuted and the queue fine: no silence from here */
    { uint64_t w = atomic_load(&s.write_pos); fake_ns += 1000000; ios_cap_silence(&s);
      CHECK(atomic_load(&s.write_pos) == w, "unmuted: silence still written"); }
    atomic_store(&g_cap.start_failed, 1);                  /* the queue would not start: silence too */
    { uint64_t w = atomic_load(&s.write_pos); fake_ns += 1000000; ios_cap_silence(&s);
      CHECK(atomic_load(&s.write_pos) > w, "start failed: no silence"); }
    atomic_store(&g_cap.start_failed, 0);

    /* the peak the 10 s report prints */
    CHECK(atomic_load(&g_cap.peak_bits) != 0, "peak not recorded");
    return fails != 0;
}
"""

with tempfile.TemporaryDirectory() as d:
    c, exe = Path(d) / "t.c", Path(d) / "t"
    c.write_text(harness)
    subprocess.run(["cc", "-std=c11", "-O1", "-Wall", "-Wno-unused-function", "-o", str(exe), str(c), "-lm"], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    print(r.stdout, end="")
    assert r.returncode == 0, "capture checks failed"
print("PASS: microphone samples reach 48k/16k/44.1k clients resampled without gaps, on every channel, "
      "in float32 and 8/16/24/32-bit PCM; a full ring drops and counts; a stopped client gets nothing; "
      "a muted microphone delivers silence in real time in the client's format, and never alongside the queue")
