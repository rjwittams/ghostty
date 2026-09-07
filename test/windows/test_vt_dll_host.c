#include <windows.h>
#include <stdio.h>

int main(void) {
    HMODULE dll = LoadLibraryA("test_vt_dll_consumer.dll");
    if (!dll) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        return 1;
    }
    int (*test_vt)(void) = (int (*)(void))GetProcAddress(dll, "test_vt");
    int result = test_vt ? test_vt() : 3;
    FreeLibrary(dll);
    if (result) fprintf(stderr, "DLL consumer failed: %d\n", result);
    return result;
}
