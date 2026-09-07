// Stub <windows.h> for building Notepad++'s LexUser.cxx on macOS.
// LexUser.cxx only needs _itoa (radix 10) from the Win32 CRT.
#pragma once
#include <cstdio>
#include <cstdlib>
static inline char *_itoa(int value, char *buffer, int radix) {
    if (radix == 16) std::snprintf(buffer, 32, "%x", value);
    else std::snprintf(buffer, 32, "%d", value);
    return buffer;
}
