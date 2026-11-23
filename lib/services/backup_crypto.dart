import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' show Random;

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The optional backup passphrase: the JSON backup file and the Google
/// Drive copy can be sealed so that a copy of the file cannot be read
/// without it. CSV and PDF exports stay plain.
///
/// The passphrase becomes a 256-bit key through PBKDF2 with HMAC-SHA256;
/// the backup, gzipped, is sealed with AES-256-GCM. Both come from the
/// `cryptography` package. A sealed backup is an envelope (a JSON object):
///
/// ```
/// format      "expense_tracker_protected"
/// version     1
/// kdf         "pbkdf2-hmac-sha256"
/// iterations  the PBKDF2 iteration count the key was made with
/// salt        base64, 16 random bytes, new each time a passphrase is set
/// cipher      "aes-256-gcm"
/// nonce       base64, 12 random bytes, new for every backup
/// made        when the backup was made, UTC ISO 8601
/// data        base64, the sealed bytes followed by the 16-byte GCM tag
/// ```
///
/// Every header field except the salt and the nonce is bound to the data as
/// associated data, so changing any of them fails the check; the salt and
/// the nonce are bound through the key and the cipher. v2.3.4 and earlier
/// reject an envelope as "Not an Expense Tracker backup file", because it
/// carries neither an `app` key nor a `transactions` list.
///
/// Scheduled Drive backups run with nobody to ask, so the derived key (never
/// the passphrase) stays in this app's private preferences, as one value
/// under this file's own key. It is not part of SettingsProvider or of any
/// backup.
class BackupPassphrase {
  BackupPassphrase._();

  /// One JSON object (key, salt, iterations, kdf), so every read and write
  /// is all or nothing.
  static const _pref = 'backup_passphrase';

  /// The iteration count new passphrases get. A test lowers it to stay
  /// fast; see [kBackupKdfIterations] for the production count.
  @visibleForTesting
  static int iterations = kBackupKdfIterations;

  /// Whether new backups are sealed: a key is stored.
  static Future<bool> isOn() async => await _stored() != null;

  /// Turns protection on with [passphrase]: a new random salt, the key
  /// derived off the main thread, and both stored. Backups from now on are
  /// sealed with it. Throws when the preference is not written.
  static Future<void> turnOn(String passphrase) async {
    final salt = _randomBytes(_saltLength);
    final count = iterations;
    final key = await compute(
      deriveBackupKey,
      (passphrase, salt, count),
      debugLabel: 'deriveBackupKey',
    );
    await _store(key: key, salt: salt, iterations: count);
  }

  /// Turns protection off: the stored key goes, and backups from now on
  /// are plain. Backups made while it was on still need the passphrase.
  /// Throws when the preference is not removed.
  static Future<void> turnOff() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_pref)) {
      throw StateError('The backup passphrase key was not removed.');
    }
  }

  static Future<void> _store({
    required Uint8List key,
    required Uint8List salt,
    required int iterations,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setString(
      _pref,
      jsonEncode({
        'key': base64Encode(key),
        'salt': base64Encode(salt),
        'iterations': iterations,
        'kdf': kBackupKdfName,
      }),
    );
    if (!written) {
      // The in-memory copy took the value before the store refused it; it
      // goes too, so this run does not seal backups with a key the next
      // run will not have.
      await prefs.remove(_pref);
      throw StateError('The backup passphrase key was not saved.');
    }
  }

  static Future<_StoredKey?> _stored() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pref);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        key: base64Decode(m['key'] as String),
        salt: base64Decode(m['salt'] as String),
        iterations: m['iterations'] as int,
        kdf: m['kdf'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// [data] sealed with the stored key, or [data] itself when protection
  /// is off. Runs off the main thread.
  static Future<Map<String, dynamic>> sealIfOn(
    Map<String, dynamic> data, {
    DateTime? now,
  }) async {
    final stored = await _stored();
    if (stored == null) return data;
    return compute(sealBackup, (
      data,
      stored.key,
      stored.salt,
      stored.iterations,
      (now ?? DateTime.now()).toUtc().toIso8601String(),
    ), debugLabel: 'sealBackup');
  }

  /// [decoded] as a plain backup map. A plain backup comes back as it is.
  /// A sealed one opens with the stored key when it was made with it (same
  /// salt, count and derivation); otherwise this throws
  /// [PassphraseNeededException]. [madeAt] dates the backup when the
  /// envelope cannot (Drive's upload time).
  ///
  /// Throws [NewerBackupFormatException] for an envelope a later release
  /// made, and [FormatException] for one that is malformed, or that the
  /// stored key matches but does not open: the file is damaged.
  static Future<Map<String, dynamic>> open(
    Map<String, dynamic> decoded, {
    DateTime? madeAt,
    String? name,
  }) async {
    if (!isSealedBackup(decoded)) return decoded;
    final header = parseEnvelope(decoded);
    final stored = await _stored();
    if (stored != null &&
        stored.kdf == kBackupKdfName &&
        stored.iterations == header.iterations &&
        listEquals(stored.salt, header.salt)) {
      final data = await compute(openSealed, (
        decoded,
        stored.key,
      ), debugLabel: 'openBackup');
      if (data == null) {
        throw const FormatException('This protected backup is damaged.');
      }
      return data;
    }
    throw PassphraseNeededException(
      decoded,
      madeAt: header.made?.toLocal() ?? madeAt,
      name: name,
    );
  }
}

/// The iteration count for a new passphrase. 600,000 is the common public
/// guidance for PBKDF2 with HMAC-SHA256, but the pure Dart derivation took
/// about 2.8 s for it on the development PC, which on a phone several times
/// slower is a wait of 8 to 14 s. 200,000 took about 0.55 s there, so a
/// phone waits 2 to 3 s. Envelopes carry their count, so a later release
/// can raise this and still open older files.
const kBackupKdfIterations = 200000;

const kSealedBackupFormat = 'expense_tracker_protected';
const kSealedBackupVersion = 1;
const kBackupKdfName = 'pbkdf2-hmac-sha256';
const kBackupCipherName = 'aes-256-gcm';

const _saltLength = 16;
const _nonceLength = 12;
const _tagLength = 16;

/// Above it an envelope is not derived: ten times the count this version
/// sets, and a crafted count would otherwise hold the phone for minutes.
const _maxIterations = 2000000;

typedef _StoredKey = ({
  Uint8List key,
  Uint8List salt,
  int iterations,
  String kdf,
});

/// A sealed backup this phone holds no key for. [open] tries a passphrase
/// without fetching the file again.
class PassphraseNeededException implements Exception {
  final Map<String, dynamic> envelope;

  /// When the backup was made, when known.
  final DateTime? madeAt;

  /// The Drive file name, for a Drive backup.
  final String? name;

  const PassphraseNeededException(this.envelope, {this.madeAt, this.name});

  /// The backup opened with [passphrase], with the key derived for it.
  /// Derives off the main thread. Throws [WrongPassphraseException] when it
  /// does not open, which is also what a changed file gives.
  Future<UnlockedBackup> open(String passphrase) async {
    final header = parseEnvelope(envelope);
    final key = await compute(
      deriveBackupKey,
      (passphrase, header.salt, header.iterations),
      debugLabel: 'deriveBackupKey',
    );
    final data = await compute(openSealed, (
      envelope,
      key,
    ), debugLabel: 'openBackup');
    if (data == null) throw const WrongPassphraseException();
    return UnlockedBackup._(data, key, header.salt, header.iterations);
  }

  @override
  String toString() => 'This backup is protected by a passphrase.';
}

/// A backup opened with a typed passphrase, and the key derived for it.
class UnlockedBackup {
  final Map<String, dynamic> data;
  final Uint8List _key;
  final Uint8List _salt;
  final int _iterations;

  const UnlockedBackup._(this.data, this._key, this._salt, this._iterations);

  /// After the restore landed: when this phone has no passphrase, it keeps
  /// the key just derived, so its backups are protected with the same
  /// passphrase from now on. A phone with protection on is left as it is.
  /// Returns whether the key was kept.
  Future<bool> adopt() async {
    if (await BackupPassphrase.isOn()) return false;
    await BackupPassphrase._store(
      key: _key,
      salt: _salt,
      iterations: _iterations,
    );
    return true;
  }
}

/// The passphrase does not open the backup (or the file was changed).
class WrongPassphraseException implements Exception {
  const WrongPassphraseException();

  @override
  String toString() => 'That passphrase does not open this backup.';
}

/// A sealed backup in a form a later release made: another version,
/// derivation or cipher, or more iterations than this one derives. Not a
/// [FormatException], so a Drive restore does not fall back past it to an
/// older file.
class NewerBackupFormatException implements Exception {
  const NewerBackupFormatException();

  String get message =>
      'This backup was made by a newer version of the app. Update the app '
      'to restore it.';

  @override
  String toString() => message;
}

/// Whether [data] is a sealed backup envelope.
bool isSealedBackup(Object? data) =>
    data is Map && data['format'] == kSealedBackupFormat;

/// The envelope's header, checked. Throws [NewerBackupFormatException] for
/// a form this version does not know, and [FormatException] for fields that
/// are missing, mistyped or the wrong length.
@visibleForTesting
({
  int iterations,
  Uint8List salt,
  Uint8List nonce,
  Uint8List sealed,
  DateTime? made,
  List<int> aad,
})
parseEnvelope(Map<String, dynamic> e) {
  const bad = FormatException('This protected backup cannot be read.');
  if (e['format'] != kSealedBackupFormat) throw bad;
  final iterations = e['iterations'];
  if (e['version'] != kSealedBackupVersion ||
      e['kdf'] != kBackupKdfName ||
      e['cipher'] != kBackupCipherName ||
      (iterations is int && iterations > _maxIterations)) {
    throw const NewerBackupFormatException();
  }
  final made = e['made'];
  if (iterations is! int || iterations < 1 || made is! String) throw bad;
  final Uint8List salt, nonce, sealed;
  try {
    salt = base64Decode(e['salt'] as String);
    nonce = base64Decode(e['nonce'] as String);
    sealed = base64Decode(e['data'] as String);
  } catch (_) {
    throw bad;
  }
  if (salt.length < _saltLength ||
      salt.length > 64 ||
      nonce.length != _nonceLength ||
      sealed.length < _tagLength) {
    throw bad;
  }
  return (
    iterations: iterations,
    salt: salt,
    nonce: nonce,
    sealed: sealed,
    made: DateTime.tryParse(made),
    aad: _aad(iterations, made),
  );
}

List<int> _aad(int iterations, String made) => utf8.encode(
  [
    kSealedBackupFormat,
    kSealedBackupVersion,
    kBackupKdfName,
    iterations,
    kBackupCipherName,
    made,
  ].join('\n'),
);

Uint8List _randomBytes(int n) {
  final random = Random.secure();
  return Uint8List.fromList([for (var i = 0; i < n; i++) random.nextInt(256)]);
}

/// PBKDF2 with HMAC-SHA256: (passphrase, salt, iterations) to a 32-byte
/// key. For [compute]: it takes the whole thread, so the package's pauses
/// for the event loop are turned off.
Future<Uint8List> deriveBackupKey((String, Uint8List, int) args) async {
  final (passphrase, salt, iterations) = args;
  final kdf = DartPbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
    pausePeriod: Duration.zero,
  );
  final key = await kdf.deriveKeyFromPassword(
    password: passphrase,
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// Seals (data, key, salt, iterations, made) into an envelope with a new
/// random nonce. For [compute].
Map<String, dynamic> sealBackup(
  (Map<String, dynamic>, Uint8List, Uint8List, int, String) args,
) {
  final (data, key, salt, iterations, made) = args;
  final clear = gzip.encode(utf8.encode(jsonEncode(data)));
  final aes = DartAesGcm.with256bits();
  final box = aes.encryptSync(
    clear,
    secretKeyData: SecretKeyData(key),
    nonce: aes.newNonce(),
    aad: _aad(iterations, made),
  );
  return {
    'format': kSealedBackupFormat,
    'version': kSealedBackupVersion,
    'kdf': kBackupKdfName,
    'iterations': iterations,
    'salt': base64Encode(salt),
    'cipher': kBackupCipherName,
    'nonce': base64Encode(box.nonce),
    'made': made,
    'data': base64Encode(box.concatenation(nonce: false)),
  };
}

/// Opens (envelope, key): the backup map, or null when the key does not
/// open it (the check failed). For [compute]; the null keeps the outcome
/// plain across the isolate. Throws [FormatException] for a malformed
/// envelope or a payload that is not a backup.
Map<String, dynamic>? openSealed((Map<String, dynamic>, Uint8List) args) {
  final (envelope, key) = args;
  final h = parseEnvelope(envelope);
  final box = SecretBox(
    h.sealed.sublist(0, h.sealed.length - _tagLength),
    nonce: h.nonce,
    mac: Mac(h.sealed.sublist(h.sealed.length - _tagLength)),
  );
  final List<int> clear;
  try {
    clear = DartAesGcm.with256bits().decryptSync(
      box,
      secretKeyData: SecretKeyData(key),
      aad: h.aad,
    );
  } on SecretBoxAuthenticationError {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(gzip.decode(clear)));
  } catch (_) {
    throw const FormatException('This protected backup cannot be read.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Not an Expense Tracker backup file');
  }
  return decoded;
}
