/* A DLL consumer must run its own CRT startup and DllMain. */
#include <windows.h>
#include <ghostty/vt.h>

static int attached;

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) attached = 1;
    return TRUE;
}

__declspec(dllexport) int test_vt(void) {
    GhosttyTerminal terminal = NULL;
    if (!attached) return 1;
    if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS) return 2;
    ghostty_terminal_free(terminal);
    return 0;
}
