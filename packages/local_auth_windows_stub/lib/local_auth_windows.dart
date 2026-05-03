import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

class WindowsAuthMessages extends AuthMessages {
  const WindowsAuthMessages();

  @override
  Map<String, String> get args => <String, String>{};
}

class LocalAuthWindows extends LocalAuthPlatform {
  static void registerWith() {
    LocalAuthPlatform.instance = LocalAuthWindows();
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    return false;
  }

  @override
  Future<bool> deviceSupportsBiometrics() async {
    return false;
  }

  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async {
    return <BiometricType>[];
  }

  @override
  Future<bool> isDeviceSupported() async {
    return false;
  }

  @override
  Future<bool> stopAuthentication() async {
    return false;
  }
}