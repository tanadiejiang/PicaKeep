import 'dart:ffi';

/// A real Windows handle without FILE_SHARE_DELETE, held only on test data.
class WindowsRenameLock {
  WindowsRenameLock(String path) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final allocate = kernel.lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)>('LocalAlloc');
    final release = kernel.lookupFunction<Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('LocalFree');
    final create = kernel.lookupFunction<
        IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Void>, Uint32,
            Uint32, IntPtr),
        int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int,
            int)>('CreateFileW');
    _close = kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseHandle');
    final memory = allocate(0, (path.length + 1) * 2);
    if (memory == nullptr) throw StateError('LocalAlloc failed');
    final text = memory.cast<Uint16>();
    try {
      for (var i = 0; i < path.length; i++) {
        text[i] = path.codeUnitAt(i);
      }
      text[path.length] = 0;
      // OPEN_EXISTING, READ|WRITE sharing, FILE_FLAG_BACKUP_SEMANTICS.
      _handle = create(text, 0x80000000, 3, nullptr, 3, 0x02000000, 0);
      if (_handle == -1) throw StateError('Cannot lock test path: $path');
    } finally {
      release(memory);
    }
  }

  late final int Function(int) _close;
  late final int _handle;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    if (_close(_handle) == 0) throw StateError('CloseHandle failed');
  }
}
