import 'dart:convert';

/// FNV-1a 64-bit hash of [text]'s UTF-8 bytes, as 16 hex characters. The
/// same on every run and every device, unlike [String.hashCode], so it can
/// be stored and compared after a restore. Not a security hash: it keeps
/// text out of storage, it does not hide guessable text.
String stableHash(String text) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(text)) {
    h ^= b;
    h *= 0x100000001b3;
  }
  // Two unsigned halves: the 64-bit value is often negative in Dart.
  return (h >>> 32).toRadixString(16).padLeft(8, '0') +
      (h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
