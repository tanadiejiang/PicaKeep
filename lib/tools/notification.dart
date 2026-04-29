
class Notifications {
  Future<bool?> requestPermission() async => true;

  Future<void> init() async {}

  void cancelAll() async {}

  void sendProgressNotification(
      int progress, int total, String title, String content) async {}

  void endProgress() async {}

  void sendNotification(String title, String content) async {}

  void sendUnimportantNotification(String title, String content) async {}
}
