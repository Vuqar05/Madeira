#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise production software-XInput notification edges, filters and scope.

This host check does not replace an SDL/game acceptance run on the iPad.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'wine/dlls/sechost/service.c'
HEADER = ROOT / 'wine/dlls/sechost/madeira_input_notifications.h'


def function(source, name):
    start = source.index('static BOOL ' + name + '(')
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


PRELUDE = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
typedef uint32_t DWORD;
typedef int BOOL;
typedef wchar_t WCHAR;
typedef struct { uint32_t a; uint16_t b,c; uint8_t d[8]; } GUID;
typedef struct { DWORD dbch_size, dbch_devicetype, dbch_reserved; } DEV_BROADCAST_HDR;
typedef struct {
    DWORD dbcc_size, dbcc_devicetype, dbcc_reserved;
    GUID dbcc_classguid;
    WCHAR dbcc_name[1];
} DEV_BROADCAST_DEVICEINTERFACE_W;
#define TRUE 1
#define FALSE 0
#define MAX_PATH 260
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define DBT_DEVTYP_DEVICEINTERFACE 5
#define DBT_DEVTYP_HANDLE 6
#define DBT_DEVICEARRIVAL 0x8000
#define DBT_DEVICEREMOVECOMPLETE 0x8004
#define IsEqualGUID(a,b) (!memcmp(a,b,sizeof(GUID)))
#define FIXME(...) ((void)0)
#define wcsicmp wcscasecmp
static const WCHAR *owner, *forward, *image;
static DWORD GetEnvironmentVariableW(const WCHAR *name, WCHAR *out, DWORD count)
{
    const WCHAR *value = !wcscmp(name,L"MADEIRA_HIDPAD_OWNER") ? owner : forward;
    if (!value) return 0;
    size_t length = wcslen(value);
    if (length >= count) return length + 1;
    wcscpy(out,value);
    return length;
}
static DWORD GetModuleFileNameW(void *module, WCHAR *out, DWORD count)
{
    size_t length = wcslen(image);
    if (length >= count) return count;
    wcscpy(out,image);
    return length;
}
'''

TEST = r'''
static unsigned arrivals, removals, hid_events, xinput_events, other_events;
static unsigned long slots_seen;
static const GUID hid = {0x4d1e55b2,0xf16f,0x11cf,{0x88,0xcb,0,0x11,0x11,0,0,0x30}};
static const GUID xi = {0x6c53d5fd,0x6480,0x440f,{0xb6,0x18,0x47,0x67,0x50,0xc5,0xe1,0xa6}};
static const GUID unrelated = {0x12345678};
static BOOL accepts(DEV_BROADCAST_HDR *event, const GUID *guid)
{
    DEV_BROADCAST_DEVICEINTERFACE_W filter = {0};
    filter.dbcc_size = sizeof(filter);
    filter.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    filter.dbcc_classguid = *guid;
    return notification_filter_matches((DEV_BROADCAST_HDR *)&filter,L"",event,L"");
}
static void emit(DWORD code, DEV_BROADCAST_HDR *header)
{
    DEV_BROADCAST_DEVICEINTERFACE_W *event = (void *)header;
    unsigned slot = 99;
    assert(header->dbch_devicetype == DBT_DEVTYP_DEVICEINTERFACE);
    assert(header->dbch_reserved == 0);
    assert(event->dbcc_size == offsetof(DEV_BROADCAST_DEVICEINTERFACE_W,dbcc_name) +
                              (wcslen(event->dbcc_name)+1)*sizeof(WCHAR));
    assert(swscanf(event->dbcc_name,L"\\\\?\\MadeiraSteamXInput#%u",&slot) == 1);
    assert(slot < 4);
    slots_seen |= 1ul << slot;
    if (code == DBT_DEVICEARRIVAL) ++arrivals;
    else { assert(code == DBT_DEVICEREMOVECOMPLETE); ++removals; }
    hid_events += accepts(header,&hid);
    xinput_events += accepts(header,&xi);
    other_events += accepts(header,&unrelated);
    DEV_BROADCAST_HDR wildcard = {0};
    assert(notification_filter_matches(&wildcard,L"",header,L""));
    DEV_BROADCAST_HDR handle_filter = {sizeof(handle_filter), DBT_DEVTYP_HANDLE, 0};
    assert(!notification_filter_matches(&handle_filter,L"",header,L""));
}
int main(void)
{
    struct madeira_input_notifications state = {0};
    madeira_input_notify_update(&state,0,emit); /* initial SDL scan sees no pad */
    assert(!arrivals && !removals);
    madeira_input_notify_update(&state,1,emit); /* hooked API becomes available later */
    assert(arrivals == 2 && removals == 0 && hid_events == 1 && xinput_events == 1);
    for (int i=0; i<100; ++i) madeira_input_notify_update(&state,1,emit);
    assert(arrivals == 2); /* packet/layout changes don't cause device churn */
    madeira_input_notify_update(&state,5,emit);
    assert(arrivals == 4 && slots_seen == 5);
    madeira_input_notify_update(&state,2,emit);
    assert(arrivals == 6 && removals == 4 && slots_seen == 7);
    madeira_input_notify_update(&state,0,emit);
    assert(removals == 6 && hid_events == 6 && xinput_events == 6 && !other_events);
    madeira_input_notify_update(&state,0xfffffff0u,emit);
    assert(arrivals == 6 && removals == 6 && state.connected == 0);
    madeira_input_notify_update(&state,8,emit);
    assert(arrivals == 8 && slots_seen == 15);
    madeira_input_notify_update(&state,0,emit);
    assert(removals == 8);

    owner=L"dockhost.exe"; forward=L"xinput1_4.dll"; image=L"C:\\games\\sample.exe";
    assert(madeira_input_notifications_enabled());
    image=L"C:\\windows\\system32\\DOCKHOST.EXE";
    assert(!madeira_input_notifications_enabled()); /* never feed output back to Steam */
    image=L"sample.exe";
    assert(madeira_input_notifications_enabled());
    forward=NULL;
    assert(!madeira_input_notifications_enabled());
    forward=L"other.dll";
    assert(!madeira_input_notifications_enabled());
    forward=L"xinput1_4.dll"; owner=NULL;
    assert(!madeira_input_notifications_enabled());
    WCHAR oversized[MAX_PATH+2];
    for (unsigned i=0; i<ARRAY_SIZE(oversized)-1; ++i) oversized[i]='x';
    oversized[ARRAY_SIZE(oversized)-1]=0;
    owner=oversized;
    assert(!madeira_input_notifications_enabled());
    owner=L"dockhost.exe"; forward=oversized;
    assert(!madeira_input_notifications_enabled());
    forward=L"xinput1_4.dll"; image=oversized;
    assert(!madeira_input_notifications_enabled());
    puts("PASS: late XInput connection, stable state, four-slot arrival/removal, real notification filters and game-only scope (ASan/UBSan)");
    return 0;
}
'''

source = SOURCE.read_text()
program = '\n'.join([PRELUDE, HEADER.read_text(),
                     function(source, 'notification_filter_matches'),
                     function(source, 'madeira_input_notifications_enabled'), TEST])
with tempfile.TemporaryDirectory(prefix='madeira-input-notifications-') as temp:
    path = Path(temp)
    (path/'check.c').write_text(program)
    subprocess.run([os.environ.get('CC', 'clang'), '-std=c11', '-g', '-O1',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    str(path/'check.c'), '-o', str(path/'check')], check=True)
    subprocess.run([str(path/'check')], check=True)
