import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// 设备身份：本机生成的 P-256 密钥对 + 安装标识。
///
/// 设计要点：
/// 1. **私钥永不出设备**，服务端只保存公钥；换机 = 新设备，不做身份迁移。
/// 2. 设备身份是**匿名**的：一串标识 + 一对密钥，不关联学号姓名。
///    （安装标识由系统 ANDROID_ID 派生，见 [load]，不含任何个人信息。）
/// 3. 懒加载：头一次用到时才生成密钥，冷启动没有额外开销。
/// 4. **重装不换设备**（2026-11-01 起）：安装标识优先从 ANDROID_ID 派生，
///    卸载重装后仍是同一个 —— 以前是纯随机值，卸一次就多一台「新设备」。
///
/// 与「云端账号」的区别：这里没有登录、没有密码、没有个人资料，
/// 只用于让服务端认出「还是同一台设备」——统计、内容授权、将来的备份都靠它。
class DeviceIdentity {
  DeviceIdentity._(this.installationId, this._privateScalar, this._publicKey);

  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const String _kInstallId = 'control_installation_id';

  /// 原生侧设备标识桥（MainActivity.kt 里的 `xiyuan/device_id`）。
  static const MethodChannel _deviceChannel = MethodChannel('xiyuan/device_id');
  static const String _kPrivateKey = 'control_device_private_key';
  static const String _kDeviceToken = 'control_device_token';
  static const String _kDeviceSerial = 'control_device_serial';
  static const String _kAccessToken = 'control_access_token';
  static const String _kRefreshToken = 'control_refresh_token';

  static final ECDomainParameters _domain = ECDomainParameters('secp256r1');

  /// 安装标识（首次启动生成，随机 16 字节 base64url）。
  final String installationId;

  final BigInt _privateScalar;
  final ECPublicKey _publicKey;

  static DeviceIdentity? _cached;

  /// 读取（必要时生成）本机设备身份。
  static Future<DeviceIdentity> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    var id = await _secure.read(key: _kInstallId);
    if (id == null || id.isEmpty) {
      // 老用户已经存过随机 id 时不会走到这里 —— 保留原值，避免和服务端已有记录对不上。
      id = await _deriveInstallId();
      await _secure.write(key: _kInstallId, value: id);
    }

    final stored = await _secure.read(key: _kPrivateKey);
    final DeviceIdentity identity;
    if (stored != null && stored.isNotEmpty) {
      final scalar = _decodeScalar(stored);
      identity = DeviceIdentity._(
        id,
        scalar,
        ECPublicKey(_domain.G * scalar, _domain),
      );
    } else {
      identity = _generate(id);
      await _secure.write(key: _kPrivateKey, value: identity.privateKeyEncoded);
    }
    _cached = identity;
    return identity;
  }

  /// 派生安装标识：优先 ANDROID_ID，取不到再退回随机。
  ///
  /// 为什么用 ANDROID_ID：它是「应用签名 + 设备 + 用户」三元组的哈希，
  /// 免权限、**卸载重装不变**，正好解决「删了重装就多一台设备」的问题；
  /// 同时它换机就会变，也满足「换机 = 新设备」的原有语义。
  ///
  /// 注意这里是**单向哈希后再取前缀**：原值不出设备，服务端只看到一个
  /// 与本机绑定的不透明串。加 `xiyuan-` 前缀是为了和历史上的随机 id
  /// （16 字节 base64url，22 位）区分开，排查时一眼能看出来。
  static Future<String> _deriveInstallId() async {
    String? androidId;
    try {
      androidId = await _deviceChannel.invokeMethod<String>('androidId');
    } catch (_) {
      // 插件通道不可用（测试环境、极少数 ROM）→ 退回随机，不影响可用性。
      androidId = null;
    }
    if (androidId == null || androidId.isEmpty) {
      return _base64Url(_randomBytes(16));
    }
    final digest = _sha256(utf8.encode('xiyuan-device|$androidId'));
    return 'xiyuan-${_base64Url(digest.sublist(0, 16))}';
  }

  /// 仅供测试：暴露派生入口，免得测试去 mock 整个安全存储。
  @visibleForTesting
  static Future<String> debugDeriveInstallId() => _deriveInstallId();

  /// 仅供测试：对拍派生算法用。
  @visibleForTesting
  static List<int> debugSha256(List<int> data) => _sha256(data);

  /// SHA-256（pointycastle 已有依赖，避免为一行哈希再引 crypto 包）。
  static Uint8List _sha256(List<int> data) {
    final digest = SHA256Digest();
    return digest.process(Uint8List.fromList(data));
  }

  static DeviceIdentity _generate(String id) {
    final random = FortunaRandom()..seed(KeyParameter(_randomBytes(32)));
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain), random));
    final pair = generator.generateKeyPair();
    return DeviceIdentity._(
      id,
      (pair.privateKey as ECPrivateKey).d!,
      pair.publicKey as ECPublicKey,
    );
  }

  /// 私钥编码（32 字节 base64url），仅用于本机安全存储。
  String get privateKeyEncoded => _base64Url(_encodeScalar(_privateScalar));

  /// 公钥（SPKI DER 的 base64url），上报给控制端保存。
  String get publicKeyEncoded {
    final point = _publicKey.Q!.getEncoded(false);
    const spkiPrefix = <int>[
      0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
      0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
      0x42, 0x00,
    ];
    return _base64Url(Uint8List.fromList([...spkiPrefix, ...point]));
  }

  /// 用本机私钥对消息签名（SHA-256/DET-ECDSA，输出 DER 的 base64url）。
  String sign(String message) {
    final signer = Signer('SHA-256/DET-ECDSA')
      ..init(
        true,
        PrivateKeyParameter<ECPrivateKey>(
          ECPrivateKey(_privateScalar, _domain),
        ),
      );
    final sig = signer.generateSignature(
      Uint8List.fromList(utf8.encode(message)),
    ) as ECSignature;
    return _base64Url(_encodeDerSignature(sig.r, sig.s));
  }

  /// 按服务端的规范化格式签名：字段逐行拼接，不允许换行。
  String signLines(List<String> lines) {
    for (final line in lines) {
      if (line.contains('\n') || line.contains('\r')) {
        throw const FormatException('signed fields cannot contain line breaks');
      }
    }
    return sign(lines.join('\n'));
  }

  /// 学号伪名：SHA-256("xiyuan-control|student|" + 学号)，小写十六进制。
  ///
  /// 服务端只保存这个伪名与学号哈希，不接触学号明文。
  static String studentAlias(String studentId) {
    final digest = SHA256Digest().process(
      Uint8List.fromList(utf8.encode('xiyuan-control|student|$studentId')),
    );
    final buffer = StringBuffer();
    for (final byte in digest) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  // ---- 设备令牌（服务端登记后下发）----

  static Future<String?> loadToken() => _secure.read(key: _kDeviceToken);

  static Future<void> saveToken(String token) =>
      _secure.write(key: _kDeviceToken, value: token);

  static Future<void> clearToken() => _secure.delete(key: _kDeviceToken);

  static Future<void> saveSerial(String serial) =>
      _secure.write(key: _kDeviceSerial, value: serial);

  static Future<String?> loadSerial() => _secure.read(key: _kDeviceSerial);

  // ---- 会话令牌（断言登录后下发）----

  static Future<String?> loadAccessToken() => _secure.read(key: _kAccessToken);

  static Future<String?> loadRefreshToken() => _secure.read(key: _kRefreshToken);

  static Future<void> saveSession(String access, String refresh) async {
    await _secure.write(key: _kAccessToken, value: access);
    await _secure.write(key: _kRefreshToken, value: refresh);
  }

  static Future<void> clearSession() async {
    await _secure.delete(key: _kAccessToken);
    await _secure.delete(key: _kRefreshToken);
  }

  /// 重置设备身份（换机/排障用：清私钥与令牌，下次生成新的）。
  static Future<void> reset() async {
    await _secure.delete(key: _kPrivateKey);
    await _secure.delete(key: _kDeviceToken);
    _cached = null;
  }

  // ---- 编解码小工具 ----

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static BigInt _decodeScalar(String encoded) {
    final padding = '=' * ((4 - encoded.length % 4) % 4);
    final bytes = base64Url.decode('$encoded$padding');
    var value = BigInt.zero;
    for (final b in bytes) {
      value = (value << 8) | BigInt.from(b);
    }
    return value;
  }

  /// 固定长度（默认 32 字节）大端编码。
  static Uint8List _encodeScalar(BigInt value, {int length = 32}) {
    final raw = _encodeMinimal(value);
    if (raw.length > length) {
      throw const FormatException('Integer does not fit requested length');
    }
    return Uint8List.fromList([
      ...List<int>.filled(length - raw.length, 0),
      ...raw,
    ]);
  }

  /// 最小长度大端编码（DER INTEGER 用）。
  static Uint8List _encodeMinimal(BigInt value) {
    if (value == BigInt.zero) return Uint8List(0);
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  static Uint8List _encodeDerSignature(BigInt r, BigInt s) {
    final body = Uint8List.fromList([
      ..._encodeDerInteger(r),
      ..._encodeDerInteger(s),
    ]);
    return Uint8List.fromList([0x30, body.length, ...body]);
  }

  static Uint8List _encodeDerInteger(BigInt value) {
    var bytes = _encodeMinimal(value);
    if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
    if ((bytes.first & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    return Uint8List.fromList([0x02, bytes.length, ...bytes]);
  }
}
