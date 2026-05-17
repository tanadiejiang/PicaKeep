import 'dart:async';

class LibraryEvent {
  const LibraryEvent({
    required this.type,
    required this.signature,
    required this.generatedAt,
  });

  factory LibraryEvent.libraryChanged(
    String signature,
    DateTime generatedAt,
  ) {
    return LibraryEvent(
      type: 'library-changed',
      signature: signature,
      generatedAt: generatedAt,
    );
  }

  final String type;
  final String signature;
  final DateTime generatedAt;

  Map<String, dynamic> toJson() => {
        'type': type,
        'signature': signature,
        'generatedAt': generatedAt.toIso8601String(),
      };
}

class LibraryEventBus {
  final StreamController<LibraryEvent> _controller =
      StreamController<LibraryEvent>.broadcast(sync: true);

  Stream<LibraryEvent> get stream => _controller.stream;

  bool get isClosed => _controller.isClosed;

  void emit(LibraryEvent event) {
    if (_controller.isClosed) {
      return;
    }
    _controller.add(event);
  }

  Future<void> close() async {
    if (_controller.isClosed) {
      return;
    }
    await _controller.close();
  }
}
