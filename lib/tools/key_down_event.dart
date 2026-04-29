class ListenVolumeController {
  final VoidCallback onUp;
  final VoidCallback onDown;

  ListenVolumeController(this.onUp, this.onDown);

  void listenVolumeChange() {}
  void stop() {}
}

typedef VoidCallback = void Function();
