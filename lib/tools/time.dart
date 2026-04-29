extension TimeExtension on DateTime {
  Duration operator -(DateTime other) => difference(other);
}
