enum ArchiveErrorCode {
  unsupportedFormat,
  encryptedArchive,
  passwordRequired,
  wrongPassword,
  unsupportedEncryption,
  corruptedArchive,
  entryNotFound,
  entryTooLarge,
  cacheLimitExceeded,
  ioError,
}

class ArchiveFailure implements Exception {
  const ArchiveFailure({
    required this.code,
    required this.debugMessage,
    this.cause,
  });

  final ArchiveErrorCode code;
  final String debugMessage;
  final Object? cause;

  String userMessage() {
    switch (code) {
      case ArchiveErrorCode.unsupportedFormat:
        return '不支持的压缩包格式';
      case ArchiveErrorCode.encryptedArchive:
      case ArchiveErrorCode.passwordRequired:
        return '该压缩包已加密，请输入密码';
      case ArchiveErrorCode.wrongPassword:
        return '密码错误或压缩包无法解密';
      case ArchiveErrorCode.unsupportedEncryption:
        return '当前压缩包加密方式暂不支持';
      case ArchiveErrorCode.corruptedArchive:
        return '压缩包已损坏或格式不正确';
      case ArchiveErrorCode.entryNotFound:
        return '压缩包内找不到指定文件';
      case ArchiveErrorCode.entryTooLarge:
        return '压缩包内文件过大，无法读取';
      case ArchiveErrorCode.cacheLimitExceeded:
        return '阅读缓存已满，请清理后重试';
      case ArchiveErrorCode.ioError:
        return '读取压缩包时发生 IO 错误';
    }
  }

  @override
  String toString() => 'ArchiveFailure($code): $debugMessage';
}
