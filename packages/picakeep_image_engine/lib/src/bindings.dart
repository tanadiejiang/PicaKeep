part of '../picakeep_image_engine.dart';

final class _NativeMetadata extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int encodedWidth;
  @Uint32()
  external int encodedHeight;
  @Uint32()
  external int format;
  @Uint32()
  external int orientation;
  @Uint32()
  external int animated;
  @Uint32()
  external int bitDepth;
  @Uint32()
  external int hasProfile;
  @Uint64()
  external int estimatedWorkingBytes;
}

final class _NativeRequest extends Struct {
  @Uint32()
  external int x;
  @Uint32()
  external int y;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int outputWidth;
  @Uint32()
  external int outputHeight;
  @Uint64()
  external int memoryBudget;
  @Uint64()
  external int diskBudget;
  external Pointer<Void> cancelToken;
}

final class _NativeResult extends Struct {
  external Pointer<Uint8> pixels;
  @Uint64()
  external int byteLength;
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int stride;
  @Uint64()
  external int workingPeak;
  @Uint64()
  external int diskBytes;
  @Uint64()
  external int elapsedMicros;
  external Pointer<Char> backend;
}

final class _NativeEncodeRequest extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  @Uint32()
  external int stride;
  @Uint32()
  external int format;
  @Uint32()
  external int quality;
  @Uint32()
  external int lossless;
  @Uint64()
  external int inputBytes;
  @Uint64()
  external int memoryBudget;
  @Uint64()
  external int outputLimit;
  external Pointer<Void> cancelToken;
}

final class _NativeEncodedResult extends Struct {
  external Pointer<Uint8> bytes;
  @Uint64()
  external int byteLength;
  @Uint64()
  external int workingPeak;
  @Uint64()
  external int elapsedMicros;
  @Uint32()
  external int format;
}

typedef _ProbeNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<_NativeMetadata>,
      Pointer<Uint8>,
      Uint64,
    );
typedef _DecodeNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<_NativeRequest>,
      Pointer<_NativeResult>,
      Pointer<Uint8>,
      Uint64,
    );
typedef _ReleaseNative = Void Function(Pointer<_NativeResult>);
typedef _TokenCreateNative = Pointer<Void> Function();
typedef _TokenActionNative = Void Function(Pointer<Void>);
typedef _AvailableMemoryNative = Uint64 Function();
typedef _DiskSpaceNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Uint64>,
      Pointer<Uint8>,
      Uint64,
      Pointer<Uint8>,
      Uint64,
    );
typedef _AbiVersionNative = Uint32 Function();
typedef _EncodeNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<_NativeEncodeRequest>,
      Pointer<_NativeEncodedResult>,
      Pointer<Uint8>,
      Uint64,
    );
typedef _EncodedReleaseNative = Void Function(Pointer<_NativeEncodedResult>);
typedef _EstimateNative =
    Uint64 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32, Uint32);

class _Bindings {
  _Bindings() {
    final override = Platform.environment['PICAKEEP_IMAGE_ENGINE_LIBRARY'];
    final library = DynamicLibrary.open(
      override ??
          (Platform.isWindows
              ? 'picakeep_image_engine.dll'
              : 'libpicakeep_image_engine.so'),
    );
    final version = library.lookupFunction<_AbiVersionNative, int Function()>(
      'pki_abi_version',
    )();
    if (version != 1) {
      throw StateError('Image engine ABI $version is unsupported');
    }
    probe = library
        .lookupFunction<
          _ProbeNative,
          int Function(
            Pointer<Utf8>,
            Pointer<_NativeMetadata>,
            Pointer<Uint8>,
            int,
          )
        >('pki_probe');
    decode = library
        .lookupFunction<
          _DecodeNative,
          int Function(
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<_NativeRequest>,
            Pointer<_NativeResult>,
            Pointer<Uint8>,
            int,
          )
        >('pki_decode_region');
    decodePrepared = library.providesSymbol('pki_decode_prepared_region')
        ? library.lookupFunction<
            _DecodeNative,
            int Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<_NativeRequest>,
              Pointer<_NativeResult>,
              Pointer<Uint8>,
              int,
            )
          >('pki_decode_prepared_region')
        : null;
    release = library
        .lookupFunction<_ReleaseNative, void Function(Pointer<_NativeResult>)>(
          'pki_release',
        );
    tokenCreate = library
        .lookupFunction<_TokenCreateNative, Pointer<Void> Function()>(
          'pki_token_create',
        );
    tokenCancel = library
        .lookupFunction<_TokenActionNative, void Function(Pointer<Void>)>(
          'pki_token_cancel',
        );
    tokenDestroy = library
        .lookupFunction<_TokenActionNative, void Function(Pointer<Void>)>(
          'pki_token_destroy',
        );
    availableMemory = library
        .lookupFunction<_AvailableMemoryNative, int Function()>(
          'pki_available_memory_bytes',
        );
    // Additive ABI-1 feature: an older image library still decodes normally,
    // but disk admission must fail explicitly rather than assume free space.
    diskSpace = library.providesSymbol('pki_query_disk_space')
        ? library.lookupFunction<
            _DiskSpaceNative,
            int Function(
              Pointer<Utf8>,
              Pointer<Uint64>,
              Pointer<Uint8>,
              int,
              Pointer<Uint8>,
              int,
            )
          >('pki_query_disk_space')
        : null;
    estimate = library
        .lookupFunction<
          _EstimateNative,
          int Function(Pointer<Utf8>, Pointer<Utf8>, int, int)
        >('pki_estimate_working_bytes');
    encode = library
        .lookupFunction<
          _EncodeNative,
          int Function(
            Pointer<Uint8>,
            Pointer<_NativeEncodeRequest>,
            Pointer<_NativeEncodedResult>,
            Pointer<Uint8>,
            int,
          )
        >('pki_encode_rgba');
    encodedRelease = library
        .lookupFunction<
          _EncodedReleaseNative,
          void Function(Pointer<_NativeEncodedResult>)
        >('pki_encoded_release');
  }
  static final instance = _Bindings();
  late final int Function(
    Pointer<Utf8>,
    Pointer<_NativeMetadata>,
    Pointer<Uint8>,
    int,
  )
  probe;
  late final int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<_NativeRequest>,
    Pointer<_NativeResult>,
    Pointer<Uint8>,
    int,
  )
  decode;
  late final int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<_NativeRequest>,
    Pointer<_NativeResult>,
    Pointer<Uint8>,
    int,
  )?
  decodePrepared;
  late final void Function(Pointer<_NativeResult>) release;
  late final Pointer<Void> Function() tokenCreate;
  late final void Function(Pointer<Void>) tokenCancel, tokenDestroy;
  late final int Function() availableMemory;
  late final int Function(
    Pointer<Utf8>,
    Pointer<Uint64>,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
  )?
  diskSpace;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, int, int) estimate;
  late final int Function(
    Pointer<Uint8>,
    Pointer<_NativeEncodeRequest>,
    Pointer<_NativeEncodedResult>,
    Pointer<Uint8>,
    int,
  )
  encode;
  late final void Function(Pointer<_NativeEncodedResult>) encodedRelease;
}
