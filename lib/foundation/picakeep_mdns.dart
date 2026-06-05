import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:picakeep/tools/android_multicast_lock.dart';

const picaKeepMdnsServiceType = '_picakeep._tcp.local';
const picaKeepMdnsServicePort = 5353;

final InternetAddress _mdnsIpv4Address = InternetAddress('224.0.0.251');

String _deviceSystem() {
  return switch (Platform.operatingSystem.toLowerCase()) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => Platform.operatingSystem.trim().isEmpty
        ? '未知系统'
        : Platform.operatingSystem,
  };
}

String _deviceName() {
  final hostName = Platform.localHostname.trim();
  return hostName.isEmpty ? '当前设备' : hostName;
}


class PicaKeepMdnsEndpoint {
  const PicaKeepMdnsEndpoint({
    required this.instanceName,
    required this.hostName,
    required this.address,
    required this.port,
    this.txt = const <String, String>{},
  });

  final String instanceName;
  final String hostName;
  final InternetAddress address;
  final int port;
  final Map<String, String> txt;
}

class PicaKeepMdnsDiscovery {
  Future<List<PicaKeepMdnsEndpoint>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    Timer? retryTimer;
    final collector = _MdnsDiscoveryCollector();
    final completer = Completer<List<PicaKeepMdnsEndpoint>>();

    await AndroidMulticastLock.instance.acquire();
    try {
      socket = await _bindMdnsSocket();
      final interfaces = await _resolveMdnsInterfaces();
      await _joinMdnsInterfaces(socket, interfaces);
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        Datagram? datagram;
        while ((datagram = socket!.receive()) != null) {
          final packet = _MdnsPacket.tryParse(datagram!.data);
          if (packet == null || !packet.isResponse) {
            continue;
          }
          collector.addPacket(packet);
        }
      });

      void sendQuery() {
        final query = _MdnsPacketBuilder.query(
          picaKeepMdnsServiceType,
          _MdnsRecordType.ptr,
        );
        socket?.send(query, _mdnsIpv4Address, picaKeepMdnsServicePort);
      }

      sendQuery();
      var retryCount = 0;
      retryTimer = Timer.periodic(const Duration(milliseconds: 650), (timer) {
        retryCount += 1;
        if (retryCount >= 3) {
          timer.cancel();
          return;
        }
        sendQuery();
      });

      await Future<void>.delayed(timeout);
      completer.complete(collector.endpoints());
    } catch (_) {
      if (!completer.isCompleted) {
        completer.complete(const <PicaKeepMdnsEndpoint>[]);
      }
    } finally {
      retryTimer?.cancel();
      await subscription?.cancel();
      socket?.close();
      await AndroidMulticastLock.instance.release();
    }
    return completer.future;
  }
}

class PicaKeepMdnsAdvertiser {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _announceTimer;
  _MdnsAdvertiseSnapshot? _snapshot;

  bool get isRunning => _socket != null;

  Future<void> start({
    required int port,
    String host = '0.0.0.0',
    String instanceLabel = 'PicaKeep',
  }) async {
    await stop();
    final addresses = await _resolveAdvertisedIpv4Addresses(host);
    if (addresses.isEmpty) {
      return;
    }
    await AndroidMulticastLock.instance.acquire();
    try {
      final socket = await _bindMdnsSocket();
      final interfaces = await _resolveMdnsInterfaces();
      await _joinMdnsInterfaces(socket, interfaces);
      final hostToken = _buildStableHostToken(addresses);
      final deviceSystem = _deviceSystem();
      final deviceName = _deviceName();
      final snapshot = _MdnsAdvertiseSnapshot(
        instanceName:
            '${_sanitizeDnsLabel(instanceLabel)}-$hostToken.$picaKeepMdnsServiceType',
        hostName: 'picakeep-$hostToken.local',
        port: port,
        addresses: addresses,
        txt: {
          'app': 'PicaKeep',
          'service': 'library',
          'status': '/status',
          'admin': '/admin',
          'deviceSystem': deviceSystem,
          'deviceName': deviceName,
        },
      );
      _socket = socket;
      _snapshot = snapshot;
      _subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final packet = _MdnsPacket.tryParse(datagram!.data);
          if (packet == null || packet.isResponse) {
            continue;
          }
          if (_shouldAnswer(packet, snapshot)) {
            _sendResponse(ttl: 120);
          }
        }
      });
      _sendResponse(ttl: 120);
      var announceCount = 0;
      _announceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        announceCount += 1;
        if (announceCount >= 2) {
          timer.cancel();
          return;
        }
        _sendResponse(ttl: 120);
      });
    } catch (_) {
      await AndroidMulticastLock.instance.release();
      rethrow;
    }
  }

  Future<void> stop() async {
    final socket = _socket;
    final snapshot = _snapshot;
    _announceTimer?.cancel();
    _announceTimer = null;
    _socket = null;
    _snapshot = null;
    await _subscription?.cancel();
    _subscription = null;
    if (socket != null && snapshot != null) {
      final goodbye = _MdnsPacketBuilder.serviceResponse(snapshot, ttl: 0);
      socket.send(goodbye, _mdnsIpv4Address, picaKeepMdnsServicePort);
    }
    socket?.close();
    await AndroidMulticastLock.instance.release();
  }

  bool _shouldAnswer(
    _MdnsPacket packet,
    _MdnsAdvertiseSnapshot snapshot,
  ) {
    for (final question in packet.questions) {
      final name = _normalizeDnsName(question.name);
      final type = question.type;
      if (type != _MdnsRecordType.any &&
          type != _MdnsRecordType.ptr &&
          type != _MdnsRecordType.srv &&
          type != _MdnsRecordType.txt &&
          type != _MdnsRecordType.a) {
        continue;
      }
      if (name == picaKeepMdnsServiceType ||
          name == _normalizeDnsName(snapshot.instanceName) ||
          name == _normalizeDnsName(snapshot.hostName)) {
        return true;
      }
    }
    return false;
  }

  void _sendResponse({required int ttl}) {
    final socket = _socket;
    final snapshot = _snapshot;
    if (socket == null || snapshot == null) {
      return;
    }
    final response = _MdnsPacketBuilder.serviceResponse(snapshot, ttl: ttl);
    socket.send(response, _mdnsIpv4Address, picaKeepMdnsServicePort);
  }
}

class _MdnsInterfaceInfo {
  _MdnsInterfaceInfo({
    required this.networkInterface,
    required this.address,
    required this.name,
  });

  final NetworkInterface networkInterface;
  final InternetAddress address;
  final String name;
}

Future<List<_MdnsInterfaceInfo>> _resolveMdnsInterfaces() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final infos = <_MdnsInterfaceInfo>[];
  final seen = <String>{};
  for (final networkInterface in interfaces) {
    for (final address in networkInterface.addresses) {
      if (seen.add('${networkInterface.name}:${address.address}')) {
        infos.add(_MdnsInterfaceInfo(
          networkInterface: networkInterface,
          address: address,
          name: networkInterface.name,
        ));
      }
    }
  }
  infos.sort((a, b) {
    final aPrivate = _isPrivateIpv4(a.address.address);
    final bPrivate = _isPrivateIpv4(b.address.address);
    if (aPrivate != bPrivate) {
      return aPrivate ? -1 : 1;
    }
    return a.address.address.compareTo(b.address.address);
  });
  return infos;
}

Future<void> _joinMdnsInterfaces(
  RawDatagramSocket socket,
  List<_MdnsInterfaceInfo> interfaces,
) async {
  socket.multicastHops = 255;
  final joined = <String>{};
  try {
    socket.joinMulticast(_mdnsIpv4Address);
  } catch (_) {}
  for (final info in interfaces) {
    if (!joined.add(info.name)) {
      continue;
    }
    try {
      socket.joinMulticast(_mdnsIpv4Address, info.networkInterface);
    } catch (_) {}
  }
}

class _MdnsDiscoveryCollector {
  final Set<String> _instances = <String>{};
  final Map<String, _SrvRecordData> _srvByInstance = <String, _SrvRecordData>{};
  final Map<String, Map<String, String>> _txtByInstance =
      <String, Map<String, String>>{};
  final Map<String, List<InternetAddress>> _addressesByHost =
      <String, List<InternetAddress>>{};

  void addPacket(_MdnsPacket packet) {
    for (final record in packet.records) {
      final recordName = _normalizeDnsName(record.name);
      if (record.type == _MdnsRecordType.ptr &&
          recordName == picaKeepMdnsServiceType &&
          record.ptrName != null) {
        _instances.add(_normalizeDnsName(record.ptrName!));
      }
      if (record.type == _MdnsRecordType.srv && record.srvData != null) {
        _srvByInstance[recordName] = record.srvData!;
        if (recordName.endsWith('.$picaKeepMdnsServiceType')) {
          _instances.add(recordName);
        }
      }
      if (record.type == _MdnsRecordType.txt) {
        _txtByInstance[recordName] = record.txt;
      }
      if (record.type == _MdnsRecordType.a && record.ipv4Address != null) {
        final addresses = _addressesByHost.putIfAbsent(
          recordName,
          () => <InternetAddress>[],
        );
        if (!addresses
            .any((address) => address.address == record.ipv4Address!.address)) {
          addresses.add(record.ipv4Address!);
        }
      }
    }
  }

  List<PicaKeepMdnsEndpoint> endpoints() {
    final endpoints = <PicaKeepMdnsEndpoint>[];
    final seen = <String>{};
    for (final instance in _instances) {
      final srv = _srvByInstance[instance];
      if (srv == null) {
        continue;
      }
      final hostName = _normalizeDnsName(srv.target);
      final addresses = _addressesByHost[hostName] ?? const <InternetAddress>[];
      for (final address in addresses) {
        final key = '${address.address}:${srv.port}';
        if (!seen.add(key)) {
          continue;
        }
        endpoints.add(
          PicaKeepMdnsEndpoint(
            instanceName: instance,
            hostName: hostName,
            address: address,
            port: srv.port,
            txt: _txtByInstance[instance] ?? const <String, String>{},
          ),
        );
      }
    }
    return endpoints;
  }
}

class _MdnsAdvertiseSnapshot {
  const _MdnsAdvertiseSnapshot({
    required this.instanceName,
    required this.hostName,
    required this.port,
    required this.addresses,
    required this.txt,
  });

  final String instanceName;
  final String hostName;
  final int port;
  final List<InternetAddress> addresses;
  final Map<String, String> txt;
}

class _MdnsPacketBuilder {
  _MdnsPacketBuilder._();

  static Uint8List query(String name, int type) {
    final writer = _ByteWriter();
    writer
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(1)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeName(name)
      ..writeUint16(type)
      ..writeUint16(_MdnsRecordClass.internet);
    return writer.toBytes();
  }

  static Uint8List serviceResponse(_MdnsAdvertiseSnapshot snapshot,
      {required int ttl}) {
    final records = <_EncodedRecord>[
      _EncodedRecord.name(
        name: picaKeepMdnsServiceType,
        type: _MdnsRecordType.ptr,
        recordClass: _MdnsRecordClass.internet,
        ttl: ttl,
        value: snapshot.instanceName,
      ),
      _EncodedRecord.srv(
        name: snapshot.instanceName,
        ttl: ttl,
        port: snapshot.port,
        target: snapshot.hostName,
      ),
      _EncodedRecord.txt(
        name: snapshot.instanceName,
        ttl: ttl,
        values: snapshot.txt,
      ),
      for (final address in snapshot.addresses)
        _EncodedRecord.a(
          name: snapshot.hostName,
          ttl: ttl,
          address: address,
        ),
    ];
    final writer = _ByteWriter();
    writer
      ..writeUint16(0)
      ..writeUint16(0x8400)
      ..writeUint16(0)
      ..writeUint16(records.length)
      ..writeUint16(0)
      ..writeUint16(0);
    for (final record in records) {
      record.writeTo(writer);
    }
    return writer.toBytes();
  }
}

class _EncodedRecord {
  const _EncodedRecord._({
    required this.name,
    required this.type,
    required this.recordClass,
    required this.ttl,
    required this.writeData,
  });

  factory _EncodedRecord.name({
    required String name,
    required int type,
    required int recordClass,
    required int ttl,
    required String value,
  }) {
    return _EncodedRecord._(
      name: name,
      type: type,
      recordClass: recordClass,
      ttl: ttl,
      writeData: (writer) => writer.writeName(value),
    );
  }

  factory _EncodedRecord.srv({
    required String name,
    required int ttl,
    required int port,
    required String target,
  }) {
    return _EncodedRecord._(
      name: name,
      type: _MdnsRecordType.srv,
      recordClass: _MdnsRecordClass.internetWithCacheFlush,
      ttl: ttl,
      writeData: (writer) {
        writer
          ..writeUint16(0)
          ..writeUint16(0)
          ..writeUint16(port)
          ..writeName(target);
      },
    );
  }

  factory _EncodedRecord.txt({
    required String name,
    required int ttl,
    required Map<String, String> values,
  }) {
    return _EncodedRecord._(
      name: name,
      type: _MdnsRecordType.txt,
      recordClass: _MdnsRecordClass.internetWithCacheFlush,
      ttl: ttl,
      writeData: (writer) {
        for (final entry in values.entries) {
          final bytes = utf8.encode('${entry.key}=${entry.value}');
          writer.writeUint8(min(bytes.length, 255));
          writer.writeBytes(bytes.take(255));
        }
      },
    );
  }

  factory _EncodedRecord.a({
    required String name,
    required int ttl,
    required InternetAddress address,
  }) {
    return _EncodedRecord._(
      name: name,
      type: _MdnsRecordType.a,
      recordClass: _MdnsRecordClass.internetWithCacheFlush,
      ttl: ttl,
      writeData: (writer) => writer.writeBytes(address.rawAddress.take(4)),
    );
  }

  final String name;
  final int type;
  final int recordClass;
  final int ttl;
  final void Function(_ByteWriter writer) writeData;

  void writeTo(_ByteWriter writer) {
    writer
      ..writeName(name)
      ..writeUint16(type)
      ..writeUint16(recordClass)
      ..writeUint32(ttl);
    final dataWriter = _ByteWriter();
    writeData(dataWriter);
    final data = dataWriter.toBytes();
    writer
      ..writeUint16(data.length)
      ..writeBytes(data);
  }
}

class _MdnsPacket {
  const _MdnsPacket({
    required this.flags,
    required this.questions,
    required this.records,
  });

  final int flags;
  final List<_MdnsQuestion> questions;
  final List<_MdnsRecord> records;

  bool get isResponse => (flags & 0x8000) != 0;

  static _MdnsPacket? tryParse(Uint8List bytes) {
    if (bytes.length < 12) {
      return null;
    }
    try {
      final reader = _DnsReader(bytes);
      reader.readUint16();
      final flags = reader.readUint16();
      final questionCount = reader.readUint16();
      final answerCount = reader.readUint16();
      final authorityCount = reader.readUint16();
      final additionalCount = reader.readUint16();
      final questions = <_MdnsQuestion>[];
      for (var i = 0; i < questionCount; i++) {
        final name = reader.readName();
        final type = reader.readUint16();
        final recordClass = reader.readUint16();
        questions.add(_MdnsQuestion(name, type, recordClass));
      }
      final records = <_MdnsRecord>[];
      final recordCount = answerCount + authorityCount + additionalCount;
      for (var i = 0; i < recordCount; i++) {
        final name = reader.readName();
        final type = reader.readUint16();
        final recordClass = reader.readUint16();
        final ttl = reader.readUint32();
        final dataLength = reader.readUint16();
        final dataOffset = reader.offset;
        reader.skip(dataLength);
        final record = _MdnsRecord.parse(
          bytes: bytes,
          name: name,
          type: type,
          recordClass: recordClass,
          ttl: ttl,
          dataOffset: dataOffset,
          dataLength: dataLength,
        );
        if (record != null) {
          records.add(record);
        }
      }
      return _MdnsPacket(
        flags: flags,
        questions: questions,
        records: records,
      );
    } catch (_) {
      return null;
    }
  }
}

class _MdnsQuestion {
  const _MdnsQuestion(this.name, this.type, this.recordClass);

  final String name;
  final int type;
  final int recordClass;
}

class _MdnsRecord {
  const _MdnsRecord({
    required this.name,
    required this.type,
    required this.recordClass,
    required this.ttl,
    this.ptrName,
    this.srvData,
    this.txt = const <String, String>{},
    this.ipv4Address,
  });

  final String name;
  final int type;
  final int recordClass;
  final int ttl;
  final String? ptrName;
  final _SrvRecordData? srvData;
  final Map<String, String> txt;
  final InternetAddress? ipv4Address;

  static _MdnsRecord? parse({
    required Uint8List bytes,
    required String name,
    required int type,
    required int recordClass,
    required int ttl,
    required int dataOffset,
    required int dataLength,
  }) {
    final dataEnd = dataOffset + dataLength;
    if (dataOffset < 0 || dataEnd > bytes.length) {
      return null;
    }
    if (type == _MdnsRecordType.ptr) {
      final ptrName = _DnsReader(bytes, offset: dataOffset).readName();
      return _MdnsRecord(
        name: name,
        type: type,
        recordClass: recordClass,
        ttl: ttl,
        ptrName: ptrName,
      );
    }
    if (type == _MdnsRecordType.srv) {
      if (dataLength < 7) {
        return null;
      }
      final dataReader = _DnsReader(bytes, offset: dataOffset);
      dataReader.readUint16();
      dataReader.readUint16();
      final port = dataReader.readUint16();
      final target = dataReader.readName();
      return _MdnsRecord(
        name: name,
        type: type,
        recordClass: recordClass,
        ttl: ttl,
        srvData: _SrvRecordData(port: port, target: target),
      );
    }
    if (type == _MdnsRecordType.txt) {
      final values = <String, String>{};
      var offset = dataOffset;
      while (offset < dataEnd) {
        final length = bytes[offset];
        offset += 1;
        if (offset + length > dataEnd) {
          break;
        }
        final text = utf8.decode(
          bytes.sublist(offset, offset + length),
          allowMalformed: true,
        );
        offset += length;
        final separator = text.indexOf('=');
        if (separator <= 0) {
          values[text] = '';
        } else {
          values[text.substring(0, separator)] = text.substring(separator + 1);
        }
      }
      return _MdnsRecord(
        name: name,
        type: type,
        recordClass: recordClass,
        ttl: ttl,
        txt: values,
      );
    }
    if (type == _MdnsRecordType.a && dataLength == 4) {
      return _MdnsRecord(
        name: name,
        type: type,
        recordClass: recordClass,
        ttl: ttl,
        ipv4Address: InternetAddress.fromRawAddress(
          bytes.sublist(dataOffset, dataEnd),
        ),
      );
    }
    return _MdnsRecord(
      name: name,
      type: type,
      recordClass: recordClass,
      ttl: ttl,
    );
  }
}

class _SrvRecordData {
  const _SrvRecordData({required this.port, required this.target});

  final int port;
  final String target;
}

class _DnsReader {
  _DnsReader(this.bytes, {this.offset = 0});

  final Uint8List bytes;
  int offset;

  int readUint16() {
    _checkReadable(2);
    final value = ByteData.sublistView(bytes, offset, offset + 2).getUint16(0);
    offset += 2;
    return value;
  }

  int readUint32() {
    _checkReadable(4);
    final value = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  String readName() {
    final result = _readDnsName(bytes, offset);
    offset = result.nextOffset;
    return result.name;
  }

  void skip(int count) {
    _checkReadable(count);
    offset += count;
  }

  void _checkReadable(int count) {
    if (offset + count > bytes.length) {
      throw const FormatException('mDNS packet truncated');
    }
  }
}

class _DnsNameReadResult {
  const _DnsNameReadResult(this.name, this.nextOffset);

  final String name;
  final int nextOffset;
}

_DnsNameReadResult _readDnsName(Uint8List bytes, int startOffset) {
  final labels = <String>[];
  var offset = startOffset;
  var nextOffset = startOffset;
  var jumped = false;
  final visited = <int>{};

  while (true) {
    if (offset >= bytes.length || !visited.add(offset)) {
      throw const FormatException('invalid mDNS name');
    }
    final length = bytes[offset];
    if ((length & 0xc0) == 0xc0) {
      if (offset + 1 >= bytes.length) {
        throw const FormatException('invalid mDNS pointer');
      }
      final pointer = ((length & 0x3f) << 8) | bytes[offset + 1];
      if (!jumped) {
        nextOffset = offset + 2;
      }
      offset = pointer;
      jumped = true;
      continue;
    }
    if ((length & 0xc0) != 0) {
      throw const FormatException('unsupported mDNS label');
    }
    offset += 1;
    if (length == 0) {
      if (!jumped) {
        nextOffset = offset;
      }
      break;
    }
    if (offset + length > bytes.length) {
      throw const FormatException('invalid mDNS label length');
    }
    labels.add(
      ascii.decode(bytes.sublist(offset, offset + length), allowInvalid: true),
    );
    offset += length;
  }
  return _DnsNameReadResult(_normalizeDnsName(labels.join('.')), nextOffset);
}

class _ByteWriter {
  final List<int> _bytes = <int>[];

  void writeUint8(int value) {
    _bytes.add(value & 0xff);
  }

  void writeUint16(int value) {
    _bytes
      ..add((value >> 8) & 0xff)
      ..add(value & 0xff);
  }

  void writeUint32(int value) {
    _bytes
      ..add((value >> 24) & 0xff)
      ..add((value >> 16) & 0xff)
      ..add((value >> 8) & 0xff)
      ..add(value & 0xff);
  }

  void writeBytes(Iterable<int> values) {
    _bytes.addAll(values.map((value) => value & 0xff));
  }

  void writeName(String name) {
    final normalized = _normalizeDnsName(name);
    if (normalized.isEmpty) {
      writeUint8(0);
      return;
    }
    for (final label in normalized.split('.')) {
      final bytes = ascii.encode(label);
      writeUint8(min(bytes.length, 63));
      writeBytes(bytes.take(63));
    }
    writeUint8(0);
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);
}

class _MdnsRecordType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const srv = 33;
  static const any = 255;
}

class _MdnsRecordClass {
  static const internet = 1;
  static const internetWithCacheFlush = 0x8001;
}

Future<RawDatagramSocket> _bindMdnsSocket() {
  return RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    picaKeepMdnsServicePort,
    reuseAddress: true,
    reusePort: !Platform.isWindows && !Platform.isAndroid,
  );
}


Future<List<InternetAddress>> _resolveAdvertisedIpv4Addresses(
    String host) async {
  final trimmedHost = host.trim();
  if (_isPrivateIpv4(trimmedHost)) {
    return [InternetAddress(trimmedHost)];
  }
  final addresses = <InternetAddress>[];
  final seen = <String>{};
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  for (final networkInterface in interfaces) {
    for (final address in networkInterface.addresses) {
      if (_isPrivateIpv4(address.address) && seen.add(address.address)) {
        addresses.add(address);
      }
    }
  }
  if (addresses.isNotEmpty) {
    return addresses;
  }
  for (final networkInterface in interfaces) {
    for (final address in networkInterface.addresses) {
      if (seen.add(address.address)) {
        addresses.add(address);
      }
    }
  }
  return addresses;
}

String _normalizeDnsName(String value) {
  var normalized = value.trim().toLowerCase();
  while (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String _sanitizeDnsLabel(String value) {
  final normalized = value.trim().isEmpty ? 'PicaKeep' : value.trim();
  final buffer = StringBuffer();
  for (final codeUnit in normalized.codeUnits) {
    final isDigit = codeUnit >= 48 && codeUnit <= 57;
    final isUpper = codeUnit >= 65 && codeUnit <= 90;
    final isLower = codeUnit >= 97 && codeUnit <= 122;
    if (isDigit || isUpper || isLower) {
      buffer.writeCharCode(codeUnit);
    } else if (buffer.isNotEmpty && !buffer.toString().endsWith('-')) {
      buffer.write('-');
    }
  }
  final label = buffer.toString().replaceAll(RegExp(r'^-+|-+$'), '');
  return label.isEmpty ? 'PicaKeep' : label;
}

String _buildStableHostToken(List<InternetAddress> addresses) {
  final sorted = addresses.map((address) => address.address).toList()..sort();
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(sorted.join('|'))) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

bool _isPrivateIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) {
    return false;
  }
  final numbers = parts.map(int.tryParse).toList(growable: false);
  if (numbers.any((number) => number == null)) {
    return false;
  }
  final first = numbers[0]!;
  final second = numbers[1]!;
  return first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
}
