import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'chaoxing_sign_models.dart';

/// Exact re-implementation of the 学习通 7.0.2 request-signing primitives,
/// recovered from `libsecuritylib.so` and the decompiled DEX images. Every
/// routine below is a byte-for-byte port of native/Java code whose disassembly
/// is cited inline.
///
/// Three independent schemes exist; they are NOT interchangeable:
///
/// 1. [infEnc] / [signedQuery] — `jui.V`/`jui.W` (`u00/C37376y`). Appends
///    `token`, `_time`, the declared-order params and an `inf_enc` MD5 to the
///    query string. Used by the `y8`/`z8` URL builders.
/// 2. [infEncInterceptor] — the OkHttp interceptor `bw/C3030g`. Same idea but
///    params are *sorted*, joined `k=v&`, and suffixed `&_key=<desKey>`.
/// 3. [cxsign] / [formSignToken] — `bw/C3028e` and `bw/C3026c`. Sorted
///    concatenation of `key + value` with **no separators**, plus a secret.
///    `cxsign` goes in a header; `signToken` is returned to the WebView.
///
/// [webRequestSign] is the RSA half of the `CLIENT_FORM_SIGN` JS bridge
/// (`vr/C37772b` → `SecurityLib.webRequestSign` → `rsa_util::private_key_sign`).
class ChaoxingSignCrypto {
  const ChaoxingSignCrypto._();

  /// `bw/C3031h.f3839a`, `u00/C37376y.f144088a` — the app-wide inf_enc token.
  static const infEncToken = '4faa8662c59590c6f43ae9fe5b002b42';

  /// `u00/C37376y.m155194B` / `bw/C3030g` ctor arg — the inf_enc DES key.
  static const infEncDesKey = 'Z(AfY@XS';

  /// Alternate token seen in `bw/C3029f.f3828c`; kept for parity, unused by the
  /// sign surface.
  static const infEncTokenAlt = 'cl7239572d1d43829a037f172b0b9247';

  /// Lowercase hex MD5 of [input] (UTF-8), the digest used by every scheme.
  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// `URLEncoder.encode(v, "UTF-8").replaceAll("\\+", "%20")`, matching
  /// `u00/C37376y.m155210R`. Java's encoder differs from Dart's
  /// [Uri.encodeQueryComponent] on exactly three characters, so the
  /// substitutions below bridge them:
  ///
  /// | input | Java | Dart | fix |
  /// |---|---|---|---|
  /// | space | `+` → then `%20` | `+` | `+` → `%20` |
  /// | `*` | `*` (literal) | `%2A` | `%2A` → `*` |
  /// | `~` | `%7E` | `~` (literal) | `~` → `%7E` |
  ///
  /// Order matters: a literal `+` in the input is already `%2B` from Dart, so
  /// the first replacement cannot corrupt it.
  static String javaUrlEncode(String value) => Uri.encodeQueryComponent(
    value,
    encoding: utf8,
  ).replaceAll('+', '%20').replaceAll('%2A', '*').replaceAll('~', '%7E');

  /// `jui.R` — the pre-image of `inf_enc`, in **declared** parameter order
  /// (not sorted). Null values are skipped entirely, exactly as the loop does.
  ///
  /// [timeMillis] is injectable so callers (and tests) can pin `_time`.
  static String infEncBase(
    List<String> names,
    List<String?> values, {
    required int timeMillis,
    String token = infEncToken,
  }) {
    if (names.length != values.length) {
      throw ArgumentError('names and values must have equal length');
    }
    final sb = StringBuffer()
      ..write('token=')
      ..write(token)
      ..write('&_time=')
      ..write(timeMillis);
    for (var i = 0; i < names.length; i++) {
      final v = values[i];
      if (v == null) continue;
      sb
        ..write('&')
        ..write(names[i])
        ..write('=')
        ..write(javaUrlEncode(v));
    }
    return sb.toString();
  }

  /// `jui.E` — appends `&inf_enc=MD5(base + "&DESKey=" + key)` to [base].
  static String infEnc(String base, {String desKey = infEncDesKey}) =>
      '$base&inf_enc=${md5Hex('$base&DESKey=$desKey')}';

  /// `jui.V` / `jui.W` — the full signed query string that `y8`/`z8` append
  /// after a `?`.
  static String signedQuery(
    List<String> names,
    List<String?> values, {
    required int timeMillis,
    String token = infEncToken,
    String desKey = infEncDesKey,
  }) => infEnc(
    infEncBase(names, values, timeMillis: timeMillis, token: token),
    desKey: desKey,
  );

  /// `bw/C3030g.m4948a` — the interceptor variant: every query param plus
  /// `_time` and `token` (plus POST form fields), **sorted by key**, joined
  /// `k=v&…`, suffixed `&_key=<desKey>`, then MD5.
  static String infEncInterceptor(
    Map<String, String> params, {
    required int timeMillis,
    String token = infEncToken,
    String desKey = infEncDesKey,
  }) {
    final all = <String, String>{
      ...params,
      '_time': timeMillis.toString(),
      'token': token,
    };
    final keys = all.keys.toList()..sort();
    final sb = StringBuffer();
    for (final k in keys) {
      if (sb.isNotEmpty) sb.write('&');
      sb
        ..write(k)
        ..write('=')
        ..write(all[k] ?? '');
    }
    sb
      ..write('&_key=')
      ..write(desKey);
    return md5Hex(sb.toString());
  }

  /// `bw/C3028e.m4943a` and `bw/C3026c.m4937b` share this shape: sort keys,
  /// concatenate `key + value` with **no separator**, append the secret, MD5.
  ///
  /// For the `cxsign` header the secret is the device-provisioned `sc`; the map
  /// must already contain `cxtime` and `cxcid`.
  static String cxsign(Map<String, String> params, String secret) {
    final keys = params.keys.toList()..sort();
    final sb = StringBuffer();
    for (final k in keys) {
      sb
        ..write(k)
        ..write(params[k] ?? '');
    }
    sb.write(secret);
    return md5Hex(sb.toString());
  }

  /// `bw/C3026c.m4937b` — the `signToken` half of `CLIENT_FORM_SIGN`. Injects
  /// `cxtime`/`cxcid` into [fields] before hashing.
  static String formSignToken({
    required Map<String, String> fields,
    required String cxtime,
    required String cxcid,
    required String secret,
  }) => cxsign({...fields, 'cxtime': cxtime, 'cxcid': cxcid}, secret);

  /// `deobfuscate(a, b, blob)` at `libsecuritylib.so:0x7a934`:
  /// `blob.replace(0, 7, a); blob.replace(len-7, 7, b)`. The APK stores the
  /// signing key with both ends scrambled; this restores it.
  static String deobfuscateKey(String blob, String head, String tail) {
    if (blob.length < 14) {
      throw ArgumentError('key blob too short to deobfuscate');
    }
    return head + blob.substring(7, blob.length - 7) + tail;
  }

  /// The obfuscated key blob verbatim from `libsecuritylib.so` file offset
  /// 333185 (848 base64 chars, loaded by `webRequestSign` at `0x7b4f4` via
  /// `memcpy(dst, 0x51581, 0x350)`), plus the two 7-char repair strings built
  /// as immediates at `0x7b518`–`0x7b558`.
  static const _obfuscatedKeyBlob =
      'MIGmFsIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBAKKJT8YxQ8N4HPsREJK06k4+itt6'
      'wyCbNEUN5ENNUX0XFD//sUwvM12VfE9ANz9QM2rLhtwFTM6W/TKJzeGV2zY2+6HGK3ksvR9cY3bE'
      'cnm4IRDQzDCO+srhq0n6HRUXdrjp8SVImIowzTRPvsQ4iCrfx3vOyEXM4Nn6Rh4SlMKLAgMBAAEC'
      'gYB0Edy/KxU6NL91Z6VPLxUX1T/yJoPL+CnmmloE2eU0kFOstFsXjal/zi2cpr4NX6eoPznKS5qi'
      '+V5NRe2ZiBunP4SiN6WZvkwYL4XCZBElstdW3/qdV4FWtCgtBqpacfOam9dT+d0q2rA4nbbpXOWh'
      'ICYKfaBBG+C8IPZGfZRh0QJBAO/lNDi62pL2spQl4To1QAZUdPK5WyIlc1NEuHlXc+asBhlwI5SH'
      'voBHXQ8+oLl6Zmj0piS9bAUu6sJB1Zj+WSkCQQCtcqGU0H645m1UzuC/Xxonnd//6eDXHdnMiOFn'
      'WdlJ9t2MhJ4qUfBmN+XH0bej+HvRl2DHPhKsJ5UegKmI7RCTAkEA2Gu69QL9dWBCMw0JZ+3qWMuQ'
      'xfkakm+e3xw8IJwY352J0yEruC/OWQQInFwvu6UFBuLPkI2jCfoNqDqkbGXqIQJBAIBvXskEbqHa'
      'N2FSY8gx0vs9A47MD6sbNpknTsmqFaWYgMu5tCkgTcRTZfpGCBcKPB2iW46OH2ONV/WjTmbPLLMC'
      'QQCKMAapcf110Kwe5H6VapWD+zC0I2nFLYYF2g/ugaNvT0udASLnEmWZLeTR5nUcfaEfwci4B4hJ'
      'UAwrPJDr5ETL';
  static const _keyBlobHead = 'MIICeAI';
  static const _keyBlobTail = 'JQ7VBIi';

  /// The deobfuscated PKCS#8 base64, i.e. exactly what
  /// `rsa_util::format_private_key` is handed. 636 DER bytes → a 1024-bit key.
  static String get privateKeyBase64 =>
      deobfuscateKey(_obfuscatedKeyBlob, _keyBlobHead, _keyBlobTail);

  static RSAPrivateKey? _cachedKey;

  /// The 1024-bit RSA private key the client signs WebView form submissions
  /// with. It ships inside the APK, which makes it public by construction —
  /// recovering it is not a secret break, and anything relying on it for
  /// authenticity is relying on nothing.
  static RSAPrivateKey privateKey() {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final der = base64Decode(privateKeyBase64);
    final key = _parsePkcs8RsaPrivateKey(Uint8List.fromList(der));
    return _cachedKey = key;
  }

  /// `rsa_util::private_key_sign` at `libsecuritylib.so:0x7d164`:
  /// `SHA256(data)` → `RSA_sign(NID_sha256 = 0x2a0, …)` → `base64_encode(…, false)`.
  /// That is textbook RSASSA-PKCS1-v1_5 with SHA-256, standard alphabet,
  /// `=` padding.
  ///
  /// [data] is already the canonicalised `key + value` concatenation produced
  /// by [webRequestSignData]; this routine only does the crypto.
  static String rsaSignBase64(String data) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey()));
    final sig = signer.generateSignature(Uint8List.fromList(utf8.encode(data)));
    return base64Encode(sig.bytes);
  }

  /// The canonicalisation half of `webRequestSign` (`0x7b2c0`–`0x7b4ac`):
  /// parse the JSON object, drop every field into a `std::map` (so keys end up
  /// **lexicographically sorted**), then concatenate `key + value` with no
  /// separator. Values go through `Json::Value::asString`.
  static String webRequestSignData(Map<String, dynamic> fields) {
    final keys = fields.keys.toList()..sort();
    final sb = StringBuffer();
    for (final k in keys) {
      sb
        ..write(k)
        ..write(jsonValueAsString(fields[k]));
    }
    return sb.toString();
  }

  /// `SecurityLib.webRequestSign(json)` end to end.
  static String webRequestSign(Map<String, dynamic> fields) =>
      rsaSignBase64(webRequestSignData(fields));

  /// Mirrors `Json::Value::asString`: strings pass through, everything else is
  /// rendered the way jsoncpp renders it (numbers bare, bools `true`/`false`,
  /// null empty). Also what `JSONObject.optString` yields in the Java layer, so
  /// `vr/C37772b`'s field bag uses this too.
  static String jsonValueAsString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) {
      if (value is double && value == value.roundToDouble()) {
        return value.toInt().toString();
      }
      return value.toString();
    }
    return jsonEncode(value);
  }

  // -------------------------------------------------------------------
  // Device registration (CxDevice.getDeviceInfo / decryptDeviceInfo)
  // -------------------------------------------------------------------

  /// The device keypair's **public** half, verbatim from `libsecuritylib.so`
  /// file offset 339481 (216 base64 chars → a 1024-bit SPKI). Both natives use
  /// this same key:
  ///
  /// - `CxDevice.getDeviceInfo`  @ `0x78754` → `rsa_util::public_key_encrypt`
  /// - `CxDevice.decryptDeviceInfo` @ `0x79314` → `rsa_util::public_key_decrypt`
  ///
  /// So the server holds the private half: the client encrypts the fingerprint
  /// outbound and "decrypts" (i.e. verifies a type-01 block) on the `clientId`
  /// the server hands back.
  static const devicePublicKeyBase64 =
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC79d8Ot0hCbxxSISC6x8SCwTBspFSzlLKHJUYqoF'
      'Nu1TSRaw4hEYkOnvEaL1VyoxV6HXcDrzwYvaFZaZaPQPFnfCHZy5dQwxcmifgSHqS+oKXw40Ys4cV'
      'IqnU5d90S7EWSRdBglX489jlqVaNcQSkDx2TYmC+DbAq9FV/BU09ISQIDAQAB';

  /// The *other* embedded public key (file offset 339042), used by
  /// `SecurityLib.verifyJsSign` — not by the device flow. Kept so the two are
  /// never confused.
  static const jsSignPublicKeyBase64 =
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCgLPYaAVr9d80PEuMWzwtg9kYPXtYvtfI9oeSHJw'
      'vxqJNDhtXJqZ7W/i/7EoGfcuZgaFg15YOC9v+yt6OHrNeEDkMrRJNnCv6moCgQ5Yahdnngny47NMa'
      '/Bk3rZHTxyp0BBOJ3AKKawCpCRCphEfZ1SuSEN6uKsY3ha+yyDO5m/wIDAQAB';

  static RSAPublicKey? _cachedDeviceKey;

  /// Parses (and caches) the device-registration RSA public key from
  /// [devicePublicKeyBase64].
  static RSAPublicKey devicePublicKey() {
    final cached = _cachedDeviceKey;
    if (cached != null) return cached;
    return _cachedDeviceKey = _parseSpkiPublicKey(
      Uint8List.fromList(base64Decode(devicePublicKeyBase64)),
    );
  }

  /// `Json::FastWriter::write` over a `Json::Value` object: jsoncpp stores
  /// members in a `std::map`, so keys come out **lexicographically sorted**,
  /// the output is compact (no spaces) and FastWriter appends a trailing `\n`.
  static String fastWriterJson(Map<String, dynamic> fields) {
    final keys = fields.keys.toList()..sort();
    final sb = StringBuffer('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) sb.write(',');
      sb
        ..write(jsoncppQuote(keys[i]))
        ..write(':')
        ..write(jsoncppValue(fields[keys[i]]));
    }
    sb.write('}\n');
    return sb.toString();
  }

  /// jsoncpp's `valueToString(String)` with the default `emitUTF8_ = false`:
  /// control characters and **everything >= 0x80** become `\uXXXX` (surrogate
  /// pairs above the BMP). Dart's [jsonEncode] leaves non-ASCII literal, which
  /// would produce a different byte string — and this output is RSA-encrypted,
  /// so any drift changes the payload.
  static String jsoncppQuote(String value) {
    final sb = StringBuffer('"');
    for (final unit in value.runes) {
      switch (unit) {
        case 0x22:
          sb.write(r'\"');
        case 0x5c:
          sb.write(r'\\');
        case 0x08:
          sb.write(r'\b');
        case 0x0c:
          sb.write(r'\f');
        case 0x0a:
          sb.write(r'\n');
        case 0x0d:
          sb.write(r'\r');
        case 0x09:
          sb.write(r'\t');
        default:
          if (unit < 0x20 || unit > 0x7e) {
            if (unit > 0xffff) {
              // jsoncpp emits astral characters as a UTF-16 surrogate pair.
              final v = unit - 0x10000;
              final high = 0xd800 + (v >> 10);
              final low = 0xdc00 + (v & 0x3ff);
              sb
                ..write('\\u${high.toRadixString(16).padLeft(4, '0')}')
                ..write('\\u${low.toRadixString(16).padLeft(4, '0')}');
            } else {
              sb.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
            }
          } else {
            sb.writeCharCode(unit);
          }
      }
    }
    sb.write('"');
    return sb.toString();
  }

  /// Serialises a single JSON [value] exactly as jsoncpp `FastWriter` would,
  /// including its non-ASCII `\uXXXX` escaping and integral-double handling.
  static String jsoncppValue(dynamic value) => switch (value) {
    null => 'null',
    final bool b => b ? 'true' : 'false',
    final num n =>
      n is double && n == n.roundToDouble() && !n.isInfinite
          ? n.toInt().toString()
          : n.toString(),
    final String s => jsoncppQuote(s),
    _ => jsonEncode(value),
  };

  static int _keyByteLength(BigInt modulus) => (modulus.bitLength + 7) ~/ 8;

  /// `rsa_util::public_key_encrypt` @ `0x7c784`: `RSA_public_encrypt(…, 1)` in
  /// a loop with `RSA_size - 11` (`sub w8, w25, #0xb` at `0x7c84c`) as the
  /// input block — i.e. chunked PKCS#1 v1.5, 117 bytes in / 128 bytes out for
  /// this 1024-bit key.
  static Uint8List rsaPublicEncryptChunked(
    Uint8List data, {
    RSAPublicKey? publicKey,
  }) {
    final key = publicKey ?? devicePublicKey();
    final keyBytes = _keyByteLength(key.modulus!);
    final blockSize = keyBytes - 11;
    if (blockSize <= 0) {
      throw const FormatException('RSA key too small for PKCS#1 v1.5');
    }
    final engine = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(key));
    final out = BytesBuilder(copy: false);
    final buf = Uint8List(keyBytes);
    for (var offset = 0; offset < data.length; offset += blockSize) {
      final len = min(blockSize, data.length - offset);
      final written = engine.processBlock(data, offset, len, buf, 0);
      out.add(buf.sublist(0, written));
    }
    return out.toBytes();
  }

  /// `rsa_util::public_key_decrypt` @ `0x7ca60`: `RSA_public_decrypt(…, 1)` —
  /// PKCS#1 v1.5 **type-01** unpadding, one `RSA_size` block at a time.
  static Uint8List rsaPublicDecryptPkcs1(
    Uint8List cipher, {
    RSAPublicKey? publicKey,
  }) {
    final key = publicKey ?? devicePublicKey();
    final keyBytes = _keyByteLength(key.modulus!);
    if (cipher.isEmpty || cipher.length % keyBytes != 0) {
      throw const FormatException(
        'ciphertext is not a whole number of RSA blocks',
      );
    }
    final engine = PKCS1Encoding(RSAEngine())
      ..init(false, PublicKeyParameter<RSAPublicKey>(key));
    final out = BytesBuilder(copy: false);
    final buf = Uint8List(keyBytes);
    for (var offset = 0; offset < cipher.length; offset += keyBytes) {
      final written = engine.processBlock(cipher, offset, keyBytes, buf, 0);
      out.add(buf.sublist(0, written));
    }
    return out.toBytes();
  }

  /// `CxDevice.getDeviceInfo(context, uniqueId, oaid, oaidState)`:
  /// `base64( RSA_public_encrypt_chunked( FastWriter(json) ) )`.
  ///
  /// The 18-field schema was read out of `0x78754` (field names via
  /// `Json::Value::operator[]`, eight of them fed by `__system_property_get`).
  /// Values are caller-supplied because half of them come from JNI
  /// (`Device::getPackageInfo`, `Device::getResInfo`) or the OAID SDK.
  static String buildDeviceInfoPayload(
    Map<String, dynamic> fields, {
    RSAPublicKey? publicKey,
  }) => base64Encode(
    rsaPublicEncryptChunked(
      Uint8List.fromList(utf8.encode(fastWriterJson(fields))),
      publicKey: publicKey,
    ),
  );

  /// `CxDevice.decryptDeviceInfo(clientId)`:
  /// `RSA_public_decrypt_PKCS1( base64_decode(clientId) )` → the JSON that
  /// `qh/C36033a` deserialises into `DeviceInfo{cid, sc}`.
  ///
  /// This is what turns a server-issued `clientId` into the `cxcid`/`sc` pair
  /// the `cxsign` and `CLIENT_FORM_SIGN` schemes need.
  static ChaoxingDeviceIdentity decryptDeviceInfo(
    String clientId, {
    RSAPublicKey? publicKey,
  }) {
    final trimmed = clientId.trim();
    if (trimmed.isEmpty) {
      throw const ChaoxingSignRejected('clientId is empty');
    }
    Uint8List cipher;
    try {
      cipher = base64Decode(trimmed);
    } on FormatException {
      throw const ChaoxingSignRejected('clientId is not valid base64');
    }
    String plain;
    try {
      plain = utf8.decode(rsaPublicDecryptPkcs1(cipher, publicKey: publicKey));
    } on Object catch (error) {
      throw ChaoxingSignRejected('clientId decryption failed: $error');
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(plain);
      json = decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } on FormatException {
      throw ChaoxingSignRejected('clientId did not decrypt to JSON: $plain');
    }
    return ChaoxingDeviceIdentity(
      cxcid: (json['cid'] ?? '').toString(),
      sc: (json['sc'] ?? '').toString(),
    );
  }

  /// `mo/C34346b.m141254a` — the `uniqueId` (a.k.a. `phoneId`) is **not**
  /// hardware-derived: it is `UUID.randomUUID().toString().replaceAll("-","")`
  /// persisted in SharedPreferences `appProfile`/`uniqueId`. Any stable
  /// 32-char hex string is therefore a legitimate value.
  static String newUniqueId() => _uuidV4Hex();

  static String _uuidV4Hex() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// `SignInfoActivity.m82182w5` — the 泛雅 sign `enc`:
  /// `MD5(signId + "-" + userId + "-" + time + "-" + phoneId)`. The separator is
  /// `Constants.ACCEPT_TIME_SEPARATOR_SERVER`, which is `"-"`.
  static String fanyaSignEnc({
    required String signId,
    required String userId,
    required String time,
    required String phoneId,
  }) => md5Hex('$signId-$userId-$time-$phoneId');

  // -------------------------------------------------------------------
  // Minimal DER reader — enough for PKCS#8 / PKCS#1 RSA keys
  // -------------------------------------------------------------------

  static RSAPrivateKey _parsePkcs8RsaPrivateKey(Uint8List der) {
    final outer = _DerReader(der);
    final seq = outer.readTlv(0x30);
    final body = _DerReader(seq);
    body.readTlv(0x02); // version
    body.readTlv(0x30); // AlgorithmIdentifier
    final pkcs1 = body.readTlv(0x04); // OCTET STRING wrapping PKCS#1
    return _parsePkcs1RsaPrivateKey(pkcs1);
  }

  static RSAPrivateKey _parsePkcs1RsaPrivateKey(Uint8List der) {
    final outer = _DerReader(der);
    final body = _DerReader(outer.readTlv(0x30));
    body.readTlv(0x02); // version
    final n = body.readInteger();
    body.readInteger(); // publicExponent — recomputed by RSAPrivateKey
    final d = body.readInteger();
    final p = body.readInteger();
    final q = body.readInteger();
    return RSAPrivateKey(n, d, p, q);
  }

  /// SubjectPublicKeyInfo: `SEQUENCE{ AlgorithmIdentifier, BIT STRING{
  /// SEQUENCE{ n, e } } }`. This is what `PEM_read_bio_RSA_PUBKEY` consumes.
  static RSAPublicKey _parseSpkiPublicKey(Uint8List der) {
    final outer = _DerReader(der);
    final body = _DerReader(outer.readTlv(0x30));
    body.readTlv(0x30); // AlgorithmIdentifier
    final bitString = body.readTlv(0x03);
    // First byte of a BIT STRING is the count of unused trailing bits.
    final inner = _DerReader(bitString.sublist(1));
    final keyBody = _DerReader(inner.readTlv(0x30));
    final n = keyBody.readInteger();
    final e = keyBody.readInteger();
    return RSAPublicKey(n, e);
  }
}

class _DerReader {
  _DerReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  int _readByte() {
    if (_pos >= _bytes.length) {
      throw const FormatException('DER truncated');
    }
    return _bytes[_pos++];
  }

  int _readLength() {
    final first = _readByte();
    if (first < 0x80) return first;
    final count = first & 0x7f;
    if (count == 0 || count > 4) {
      throw const FormatException('unsupported DER length');
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | _readByte();
    }
    return value;
  }

  Uint8List readTlv(int expectedTag) {
    final tag = _readByte();
    if (tag != expectedTag) {
      throw FormatException(
        'expected DER tag 0x${expectedTag.toRadixString(16)}, '
        'got 0x${tag.toRadixString(16)}',
      );
    }
    final length = _readLength();
    if (_pos + length > _bytes.length) {
      throw const FormatException('DER value runs past the end');
    }
    final out = _bytes.sublist(_pos, _pos + length);
    _pos += length;
    return out;
  }

  BigInt readInteger() {
    final bytes = readTlv(0x02);
    var value = BigInt.zero;
    for (final b in bytes) {
      value = (value << 8) | BigInt.from(b);
    }
    return value;
  }
}
