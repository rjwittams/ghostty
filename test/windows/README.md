# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## libghostty-vt DLL consumer

`test_vt_dll_consumer.cmd` builds a C DLL that links against the installed
Ghostty VT import library, then loads it from a separate executable. It checks
that the consumer's own `DllMain` runs and that it can create and free a terminal.
Run from an MSVC developer prompt after building libghostty-vt:

```
zig build -Demit-lib-vt=true -Dsimd=true -Doptimize=ReleaseSafe
test\windows\test_vt_dll_consumer.cmd zig-out
```

With Zig 0.16's unfiltered import library, the consumer resolves its startup
symbol from Ghostty and skips its own initialization. This test reports
`DLL consumer failed: 1`. The installed import library must expose only the
`ghostty_*` C API; Ghostty's own startup remains in its DLL.
