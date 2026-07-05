# Vulkan import library (Windows cross-compile)

`vk.zig` declares the core Vulkan entry points as `extern "vulkan" fn …`, so the
Windows linker needs a `vulkan.lib` import library resolving them to the loader
DLL (`vulkan-1.dll`, shipped with GPU drivers / provided by Wine's winevulkan).

- `vulkan.def` — the export list (the 66 core symbols zuer links) with
  `LIBRARY vulkan-1.dll`. This is the source of truth.
- `vulkan.lib` — the import library generated from it, committed so the build
  needs no dlltool step. Regenerate after editing the .def with:

  ```
  zig dlltool -m i386:x86-64 -d vulkan.def -D vulkan-1.dll -l vulkan.lib
  ```

Linux/macOS link the system Vulkan loader instead and ignore this directory.
