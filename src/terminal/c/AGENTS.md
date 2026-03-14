# libghostty-vt C API

- C API must be designed with ABI compatibility in mind
- Zig tagged unions must be converted to C ABI compatible unions
  via `lib.TaggedUnion`.
- Any functions must be updated all the way through from here to
  `src/terminal/c/main.zig` to `src/lib_vt.zig` and the headers
  in `include/ghostty/vt.h`.
- In `include/ghostty/vt.h`, always sort the header contents by:
  (1) macros, (2) forward declarations, (3) types, (4) functions
