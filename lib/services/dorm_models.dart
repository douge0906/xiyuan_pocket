part of 'dorm_service.dart';

class DormBuilding {
  const DormBuilding({
    required this.feeitemid,
    required this.value,
    required this.name,
    this.campus = '1',
    this.available = true,
  });

  final int feeitemid;

  /// 形如 `A7&李园贰號A7`，服务端要求的原样格式。
  final String value;

  /// 界面显示的短名（李二 / 桃一 / 梅三）。
  final String name;

  /// 该楼栋所属校区的「value」（不同片区编码不同：梅园是一长串数字）。
  final String campus;

  /// 平台是否已开通该楼栋。
  final bool available;
}

class DormInfo {
  const DormInfo({
    required this.feeitemid,
    required this.buildingValue,
    required this.buildingName,
    required this.room,
    this.campus = '1',
  });

  final int feeitemid;
  final String buildingValue;
  final String buildingName;
  final String room;
  final String campus;

  String get display => '$buildingName $room';

  Map<String, dynamic> toMap() => {
        'feeitemid': feeitemid,
        'value': buildingValue,
        'name': buildingName,
        'room': room,
        'campus': campus,
      };

  static DormInfo? fromMap(Map<String, dynamic> m) {
    final fee = m['feeitemid'];
    final value = (m['value'] ?? '').toString();
    final name = (m['name'] ?? '').toString();
    final room = (m['room'] ?? '').toString();
    if (fee is! int || value.isEmpty || name.isEmpty || room.isEmpty) {
      return null;
    }
    return DormInfo(
      feeitemid: fee,
      buildingValue: value,
      buildingName: name,
      room: room,
      campus: (m['campus'] ?? '1').toString(),
    );
  }
}

class ElectricityInfo {
  const ElectricityInfo({
    required this.text,
    required this.balance,
    required this.kwh,
    required this.buildingName,
    required this.room,
  });

  /// 平台原句：`当前余额468.89元,当前剩余电量868.32度`
  final String text;
  final double? balance;
  final double? kwh;
  final String buildingName;
  final String room;
}

/// 宿舍信息本机存储（用户页与电费卡片共用）。
class DormStore {
  /// 当前宿舍（**变更即通知**）。
  ///
  /// 之前只有一个 `load()`，用户在「我的」页改完宿舍，首页卡片完全不知道，
  /// 电费既不刷新也查的是旧房间（2026-10-26 用户反馈）。所有读写都经过
  /// 这个 notifier，卡片监听它就能实时跟上。
  static final ValueNotifier<DormInfo?> current =
      ValueNotifier<DormInfo?>(null);

  static const String _kFee = 'dorm_feeitemid_v1';
  static const String _kValue = 'dorm_building_value_v1';
  static const String _kName = 'dorm_building_name_v1';
  static const String _kRoom = 'dorm_room_v1';
  static const String _kCampus = 'dorm_campus_v1';

  static Future<DormInfo?> load() async {
    final p = await SharedPreferences.getInstance();
    final fee = p.getInt(_kFee);
    final value = p.getString(_kValue);
    final name = p.getString(_kName);
    final room = p.getString(_kRoom);
    if (fee == null || value == null || name == null || room == null) {
      current.value = null;
      return null;
    }
    final info = DormInfo.fromMap({
      'feeitemid': fee,
      'value': value,
      'name': name,
      'room': room,
      'campus': p.getString(_kCampus) ?? '1',
    });
    current.value = info;
    return info;
  }

  static Future<void> save(DormInfo d) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kFee, d.feeitemid);
    await p.setString(_kValue, d.buildingValue);
    await p.setString(_kName, d.buildingName);
    await p.setString(_kRoom, d.room);
    await p.setString(_kCampus, d.campus);
    current.value = d;
  }
}

class CardQueryResult {
  const CardQueryResult({this.balance, this.reason});

  final double? balance;
  final String? reason;
}

class CardTxn {
  const CardTxn({
    required this.time,
    required this.title,
    required this.place,
    required this.amountYuan,
    required this.isIncome,
    required this.balanceYuan,
  });

  final String time;
  final String title;
  final String place;
  final double amountYuan;
  final bool isIncome;
  final double? balanceYuan;
}

class CardTurnoverPage {
  const CardTurnoverPage({
    required this.items,
    required this.total,
    required this.current,
    required this.pages,
  });

  final List<CardTxn> items;
  final int total;
  final int current;
  final int pages;
}
