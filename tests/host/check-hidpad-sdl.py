#!/usr/bin/env python3
"""Steam Input's virtual Xbox pad, read the way Valve's client reads it.

Valve's client in Dock opens the HID pad through SDL's HIDAPI Xbox One driver
(the x64 SDL3.dll build/sdl3/build.sh builds, upstream and unmodified). On
Windows that driver asks hidapi for the report descriptor, which hidapi
rebuilds from hid.dll's preparsed data
(hidapi/windows/hidapi_descriptor_reconstruct.c), and then reads every report
with SDL's own descriptor parser (SDL_report_descriptor.c). This check runs
that chain on the host:

  hidpad_xbox_descriptor -> Wine's hidparse.sys preparsed data (as the
  wineserver serves it) -> hidapi's reconstruction -> SDL_ParseReportDescriptor
  -> the field checks HIDAPI_DriverXboxOne_InitDevice makes -> SDL_ReadReportData
  on the reports hidpad_xbox_input builds.

It also checks the byte offsets SDL's descriptor-less Bluetooth reader uses.
A layout that parses in Wine but not after reconstruction (for example a
nested output collection that splits report 0x01, which makes SDL restart its
bit offsets) fails here.

Needs the wine submodule (WINE_SRC), SDL's source as build/sdl3/build.sh
fetches it (SDL_SRC, default build/sdl3/work/src) and a C compiler (CC).
Without the SDL tree it prints SKIP.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
wine = Path(os.environ.get('WINE_SRC', root / 'wine'))
sdl = Path(os.environ.get('SDL_SRC', root / 'build/sdl3/work/src'))
if not (wine / 'dlls/hidparse.sys/main.c').exists():
    raise SystemExit(f'SKIP: no Wine tree at {wine} (set WINE_SRC)')
reconstruct = sdl / 'src/hidapi/windows/hidapi_descriptor_reconstruct.c'
parser = sdl / 'src/joystick/hidapi/SDL_report_descriptor.c'
if not reconstruct.exists() or not parser.exists():
    raise SystemExit(f'SKIP: no SDL source at {sdl} (run build/sdl3/build.sh or set SDL_SRC)')

# The few SDL internals the two files use, from the C library.
shim = r'''
#ifndef SHIM_SDL_INTERNAL
#define SHIM_SDL_INTERNAL
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t Uint8; typedef uint16_t Uint16; typedef uint32_t Uint32; typedef int32_t Sint32; typedef uint64_t Uint64;
#define SDL_malloc malloc
#define SDL_free free
#define SDL_realloc realloc
#define SDL_memset memset
#define SDL_strlen strlen
#define SDL_zerop(p) memset((p), 0, sizeof(*(p)))
#define SDL_assert(x) ((void)0)
#define SDL_FALLTHROUGH
#define SDL_arraysize(a) (sizeof(a) / sizeof((a)[0]))
#define SDL_COMPILE_TIME_ASSERT(name, x) typedef int compile_time_assert_##name[(x) * 2 - 1]
static inline size_t SDL_strlcat(char *d, const char *s, size_t n)
{ size_t l = strlen(d); if (l + 1 < n) strncat(d, s, n - l - 1); return l + strlen(s); }
static inline int SDL_vasprintf(char **out, const char *f, va_list ap) { return vasprintf(out, f, ap); }
static inline bool SDL_SetError(const char *f, ...) { (void)f; return false; }
static inline const char *SDL_GetError(void) { return ""; }
static inline bool SDL_Unsupported(void) { return false; }
static inline void SDL_Log(const char *f, ...) { (void)f; }
static inline void *SDL_LoadFile(const char *f, size_t *n) { (void)f; (void)n; return NULL; }
#endif
'''

test = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "hidparse_ios.h"
#include "hidpad_reports.h"

/* SDL_report_descriptor.h, without SDL_internal.h's Windows clash. */
typedef struct { uint8_t report_id; uint32_t usage; int bit_offset; int bit_size; } DescriptorInputField;
typedef struct { int field_count; DescriptorInputField *fields; } SDL_ReportDescriptor;
extern SDL_ReportDescriptor *SDL_ParseReportDescriptor(const uint8_t *descriptor, int size);
extern bool SDL_DescriptorHasUsage(SDL_ReportDescriptor *descriptor, uint16_t page, uint16_t usage);
extern bool SDL_ReadReportData(const uint8_t *data, int size, int bit_offset, int bit_size, uint32_t *value);
extern int hid_winapi_descriptor_reconstruct_pp_data(void *preparsed, unsigned char *buf, size_t size);

#define USAGE(page, usage) ((uint32_t)(page) << 16 | (usage))

static SDL_ReportDescriptor *descriptor;

/* HIDAPI_DriverXboxOne_InitDevice: collapse the run of buttons into one field,
 * then require X, Y and 12 or 15 buttons. */
static int collapse_buttons( void )
{
    int i, j, count = 0;
    for (i = 0; i < descriptor->field_count; i++)
    {
        DescriptorInputField *field = &descriptor->fields[i];
        if (field->usage != USAGE(9, 1)) continue;
        for (j = i; j < descriptor->field_count; j++)
        {
            if (descriptor->fields[j].usage != field->usage + (j - i) ||
                descriptor->fields[j].bit_offset != field->bit_offset + (j - i)) break;
            count++;
        }
        field->bit_size = count;
        memmove( &descriptor->fields[i + 1], &descriptor->fields[i + count],
                 (descriptor->field_count - i - count) * sizeof(descriptor->fields[0]) );
        descriptor->field_count -= count - 1;
        break;
    }
    return count;
}

static uint32_t read_field( const unsigned char *r, unsigned int len, uint32_t usage )
{
    int i;
    uint32_t v = 0xdeadbeef;
    for (i = 0; i < descriptor->field_count; i++)
    {
        const DescriptorInputField *f = &descriptor->fields[i];
        if (f->usage != usage || f->report_id != r[0]) continue;
        /* HIDAPI_DriverXboxOne_HandleDescriptorReport skips the report ID. */
        assert( SDL_ReadReportData( r + 1, len - 1, f->bit_offset, f->bit_size, &v ) );
        return v;
    }
    assert( !"usage not found" );
    return v;
}

static int bit_size( uint32_t usage )
{
    int i;
    for (i = 0; i < descriptor->field_count; i++)
        if (descriptor->fields[i].usage == usage) return descriptor->fields[i].bit_size;
    return -1;
}

int main( void )
{
    const struct hidpad_identity *id = hidpad_identity_from_env( "xbox" );
    struct hidpad_report_state st = {0};
    struct winios_hidpad pad = {0};
    unsigned short in[256], out[256], feat[256];
    unsigned char rebuilt[1024], r[64];
    unsigned int len, size, i;
    const unsigned char *desc = hidpad_descriptor( id, &len );
    void *pre = madeira_hidparse_preparse( desc, len, &size, in, out, feat );
    int n;

    assert( pre );
    n = hid_winapi_descriptor_reconstruct_pp_data( pre, rebuilt, sizeof(rebuilt) );
    assert( n > 0 );
    descriptor = SDL_ParseReportDescriptor( rebuilt, n );
    assert( descriptor );
    assert( SDL_DescriptorHasUsage( descriptor, 1, 0x30 ) && SDL_DescriptorHasUsage( descriptor, 1, 0x31 ) );
    assert( collapse_buttons() == 15 );
    /* The driver's dispatch: 16-bit X/Y/Z/Rz are sticks, Brake/Accelerator triggers. */
    assert( bit_size( USAGE(1, 0x30) ) == 16 && bit_size( USAGE(1, 0x31) ) == 16 );
    assert( bit_size( USAGE(1, 0x32) ) == 16 && bit_size( USAGE(1, 0x35) ) == 16 );
    assert( bit_size( USAGE(2, 0xc5) ) == 10 && bit_size( USAGE(2, 0xc4) ) == 10 );
    assert( bit_size( USAGE(1, 0x39) ) == 4 && bit_size( USAGE(9, 1) ) == 15 );
    for (i = 0; i < (unsigned int)descriptor->field_count; i++) assert( descriptor->fields[i].report_id == 1 );

    /* Every value read through the rebuilt descriptor, and at the offsets
     * SDL's Bluetooth reader uses without one. */
    pad.connected = 1;
    pad.lx = -32768; pad.ly = 32767; pad.rx = 12345; pad.ry = -1;
    pad.left_trigger = 255; pad.right_trigger = 128;
    pad.buttons = HIDPAD_XI_A | HIDPAD_XI_Y | HIDPAD_XI_RSHOULDER | HIDPAD_XI_START | HIDPAD_XI_RTHUMB |
                  HIDPAD_XI_DPAD_RIGHT;
    len = hidpad_input_report( id, &pad, &st, 0, r );
    assert( len == 17 );   /* SDL: report 0x01 of more than 16 bytes, buttons at [14..16] */
    assert( read_field( r, len, USAGE(1, 0x30) ) == 0 && (r[1] | r[2] << 8) == 0 );
    assert( read_field( r, len, USAGE(1, 0x31) ) == 1 && (r[3] | r[4] << 8) == 1 );
    assert( read_field( r, len, USAGE(1, 0x32) ) == 12345 + 32768 && (r[5] | r[6] << 8) == 12345 + 32768 );
    assert( read_field( r, len, USAGE(1, 0x35) ) == 32769 && (r[7] | r[8] << 8) == 32769 );
    assert( read_field( r, len, USAGE(2, 0xc5) ) == 1023 && (r[9] | r[10] << 8) == 1023 );
    assert( read_field( r, len, USAGE(2, 0xc4) ) == 514 && (r[11] | r[12] << 8) == 514 );
    assert( read_field( r, len, USAGE(1, 0x39) ) == 3 && r[13] == 3 );
    /* Buttons 1 A, 5 Y, 8 RB, 12 Menu, 15 RS. */
    assert( read_field( r, len, USAGE(9, 1) ) == (1u << 0 | 1u << 4 | 1u << 7 | 1u << 11 | 1u << 14) );
    assert( r[14] == (0x01 | 0x10 | 0x80) && r[15] == (0x08 | 0x40) && r[16] == 0 );
    free( pre );
    printf( "PASS: Xbox descriptor rebuilt by hidapi from Wine's preparsed data; SDL reads every axis, "
            "trigger, hat and button at the right offset\n" );
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-hidpad-sdl-') as tmp:
    tmp = Path(tmp)
    (tmp / 'shim').mkdir()
    (tmp / 'shim/SDL_internal.h').write_text(shim)
    (tmp / 'check.c').write_text(test)
    cc = os.environ.get('CC', 'cc')
    wineflags = ['-std=gnu11', '-O1', '-fno-builtin', '-fshort-wchar', '-Wno-format', '-D__WINESRC__',
                 '-DWINE_UNIX_LIB', '-I', str(wine / 'include'), '-I', str(root / 'build/hidpad')]
    objs = []
    for name, src, flags in [
        ('hidparse', root / 'build/hidpad/hidparse_ios.c',
         wineflags + [f'-DMADEIRA_HIDPARSE_MAIN="{wine}/dlls/hidparse.sys/main.c"']),
        ('reconstruct', reconstruct,
         wineflags + ['-include', str(wine / 'include/windef.h'), '-include', str(wine / 'include/winternl.h'),
                      '-I', str(tmp / 'shim'), '-I', str(reconstruct.parent)]),
        ('parser', parser, ['-std=gnu11', '-O1', '-I', str(tmp / 'shim'), '-I', str(parser.parent)]),
        ('check', tmp / 'check.c', wineflags + ['-Wall', '-Werror', '-Wno-unused-function']),
    ]:
        obj = tmp / f'{name}.o'
        subprocess.run([cc, *flags, '-c', str(src), '-o', str(obj)], check=True)
        objs.append(str(obj))
    subprocess.run([cc, *objs, '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True)
