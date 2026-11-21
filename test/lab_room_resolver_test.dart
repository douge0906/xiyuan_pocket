import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/labs/lab_room_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置对照表：实验室名换成楼栋+房号', () async {
    final r = await LabRoomResolver.instance();

    // 「实验室2」这类实例编号 + 末尾实验室编码，命中基础实验室名
    expect(r.resolvePlace('电路与电子技术实验室2(21201032)').value, '思贤楼201');
    expect(r.resolvePlace('电路与电子技术实验室5(21201035)').value, '思贤楼201');

    // 已经是「楼栋+房号」→ 只做空格归一化，其余不动
    expect(r.resolvePlace('思齐楼309').value, '思齐楼309');
    expect(r.resolvePlace('思齐楼 309').value, '思齐楼309');

    // 有实验室名但没有房号 → 保持原值
    expect(r.resolvePlace('外语自主学习室3').value, '外语自主学习室3');

    // 完全没命中 → 保持原值
    expect(r.resolvePlace('勤学楼301').value, '勤学楼301');
    expect(r.resolvePlace('').value, '');
  });

  test('对照表读取到 126 条记录', () async {
    final r = await LabRoomResolver.instance();
    // 楼栋名来自对照表，用来判断「已经是标准教室」
    expect(r.buildings, contains('思齐楼'));
    expect(r.buildings, contains('思贤楼'));
  });

  test('名称包含匹配取最长项，不误伤短名', () {
    final r = LabRoomResolver.fromJsonString('''
      {"entries":[
        {"name":"软件工程实验室","building":"思源楼","room":"310"},
        {"name":"网络工程综合实验室","building":"思源楼","room":"402"}
      ]}
    ''');
    expect(r.resolvePlace('软件工程实验室2').value, '思源楼310');
    expect(r.resolvePlace('网络工程综合实验室（A）').value, '思源楼402');
    expect(r.resolvePlace('实验室').value, '实验室');
  });
}
