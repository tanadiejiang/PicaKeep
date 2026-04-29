class Res<T> {
  final String? errorMessage;
  final T? _data;
  final dynamic subData;

  const Res(T data, {this.errorMessage, this.subData}) : _data = data;

  const Res.error(this.errorMessage, {this.subData}) : _data = null;

  T get data => _data!;

  bool get error => errorMessage != null;
}
