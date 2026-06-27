import 'package:flutter/foundation.dart';

@immutable
class Res<T> {
  const Res(this._data, {this.errorMessage, this.subData});

  const Res.error(String err)
      : _data = null,
        subData = null,
        errorMessage = err;

  Res.fromErrorRes(Res another, {this.subData})
      : _data = null,
        errorMessage = another.errorMessageWithoutNull;

  final String? errorMessage;
  final T? _data;
  final dynamic subData;

  String get errorMessageWithoutNull => errorMessage ?? 'Unknown Error';

  bool get error => errorMessage != null;

  bool get success => !error;

  T get data => _data ?? (throw Exception(errorMessage));

  T? get dataOrNull => _data;

  @override
  String toString() => _data.toString();
}
