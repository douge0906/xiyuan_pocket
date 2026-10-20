import 'package:flutter/material.dart';

/// 统一的学期选择器（2026-10-20）。
///
/// 样式：**纯白底** + 1px 细边框 + 20 圆角，与待办日历里的日期选择面板一致。
/// 不跟随深色模式变暗 —— 用户明确要求「选择类弹窗统一用白色」。
///
/// 返回：选中的下标；直接关闭返回 null。
Future<int?> showSemesterPicker(
  BuildContext context, {
  required List<String> labels,
  required int currentIndex,
  String title = '选择学期',
}) {
  if (labels.isEmpty) return Future<int?>.value();
  final safeIndex = currentIndex.clamp(0, labels.length - 1);

  return showDialog<int>(
    context: context,
    builder: (ctx) {
      const ink = Color(0xFF1F1F1F);
      const sub = Color(0xFF9CA3AF);
      const border = Color(0xFFE8E8EE);

      return Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: ink),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded,
                          size: 20, color: sub),
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: border),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: labels.length,
                  itemBuilder: (_, i) {
                    final selected = i == safeIndex;
                    return InkWell(
                      onTap: () => Navigator.of(ctx).pop(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                labels[i],
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: ink,
                                ),
                              ),
                            ),
                            if (i == 0 && !selected)
                              const Text('本学期',
                                  style:
                                      TextStyle(fontSize: 12, color: sub)),
                            if (selected)
                              const Icon(Icons.check_rounded,
                                  size: 18, color: Color(0xFF1F6F5C)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 生成最近 [terms] 个学期的标签（默认 8 个 = 4 学年，覆盖本科全程）。
///
/// 格式与教务一致：`2025-2026 第1学期`。8 月及以后算新学年的第一学期。
List<String> recentSemesterLabels({int terms = 8}) {
  final now = DateTime.now();
  var year = now.month >= 8 ? now.year : now.year - 1;
  var term = now.month >= 8 ? 1 : 2;
  final labels = <String>[];
  for (var i = 0; i < terms; i++) {
    labels.add('$year-${year + 1} 第$term学期');
    if (term == 2) {
      year -= 1;
      term = 1;
    } else {
      term = 2;
    }
  }
  return labels;
}
