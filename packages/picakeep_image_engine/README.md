# PicaKeep original-image regions

Android and Windows share a versioned FFI core. Flutter plugin registration
loads/bundles the library; control metadata uses a small MethodChannel, while
pixels travel through FFI on worker isolates. This is a copy-based bridge.

```dart
const engine = PicakeepImageEngine();
final metadata = await engine.probe(readableOriginalPath);
final pixels = await engine.decodeRegion(
  readableOriginalPath,
  const NativeImageRect(0, 0, 512, 512),
  backingPath: perSourceVersionManagedBackingPath,
  memoryBudgetBytes: availablePerJobBudget,
  diskBudgetBytes: reservedBackingAndWorkspaceBudget,
);
// Pass pixels.bytes / stride / rgba8888 to ImageDescriptor.raw.
// Default bytes are straight alpha. For ImageDescriptor.raw, pass
// premultiplyAlpha: true to decodeRegion: conversion stays in its worker.
// pixels.premultipliedAlpha records the actual representation.
pixels.dispose();
```

Regions and metadata dimensions use EXIF-normalized original coordinates.
Encoded dimensions and orientation remain separately available. sRGB RGB ICC
conversion occurs once before region sampling. Native 1:1 pixels are not
recompressed. Original files are opened read-only.

Baseline JPEG native tiles can use bounded crop/skip scanlines before a backing
exists. Other routes prepare an exact disk pixel layer. `prepareBacking` lets
the application's idle queue create this layer explicitly. Large WebP needs
admission for actual internal arrays and mapped output. The memory estimate is
conservative, and actual tracked peak is returned. `availableMemoryBytes`
checks real system availability; decode admission also reserves 256MiB plus
25% of currently available memory for other work.

The app must bound simultaneous jobs, protect original/backing leases, reserve
disk before launching, register final backing file size after completion, and
evict only unleased backing files. Returned `diskBytes` is this operation's
workspace peak; progressive JPEG coefficient files are temporary and are not
part of the final persistent file's size. A completed raw backing has a 128-byte
header plus 4 bytes per encoded source pixel.

`NativeCancellationToken.dispose` cancels pending workers and defers its native
free until they return. `NativePixelBuffer.dispose` drops its owned Dart pixels
after the display bridge has acquired them. Neither action deletes originals.

Native sources, hashes, build adapters and format boundaries are in
[DEPENDENCIES.md](DEPENDENCIES.md). Codec and core targets are optimized inside
debug/profile application builds (`PKI_NATIVE_OPTIMIZE=ON`); this does not change
the Flutter application mode. No application release build is required.

For local standalone verification, configure native/CMakeLists.txt with
PKI_BUILD_TESTS=ON, build `pki_validate` in Debug, then run the test scripts in
native/tests. `PICAKEEP_IMAGE_ENGINE_LIBRARY` may explicitly point Dart tests to
that compiled DLL. Application builds and installs remain coordinated by the
parent task.
