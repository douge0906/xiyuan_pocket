import 'package:flutter/material.dart';

/// 外部站点快捷入口（成绩页 / 考试页共用，v2.4.7）。
///
/// 刻意做得紧凑：一行两枚小按钮，不占太大版面。

/// 教务系统登录页 —— 「与 App 查询等价的另一种方式」。
/// 注意：必须用这个完整登录页地址；只写站点根 `https://jwgl.cwxu.edu.cn/`
/// 在浏览器里打不开（正方教务不会自动跳登录）。
const String kJwglLoginUrl =
    'https://jwgl.cwxu.edu.cn/jwglxt/xtgl/login_slogin.html';

/// 全国大学英语四、六级考试
const String kCetUrl = 'https://cet.neea.edu.cn/';

/// 全国计算机等级考试
const String kNcreUrl = 'https://ncre.neea.edu.cn/';

/// 紧凑的一行两枚按钮：四六级查询 / 计算机等级
class SiteLinksRow extends StatelessWidget {
  final Future<void> Function(String url) onOpen;

  const SiteLinksRow({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.grey.shade300 : const Color(0xFF4B5563);
    final side =
        isDark ? const Color(0xFF3A3A3A) : const Color(0xFFD1D5DB);

    Widget btn(IconData icon, String label, String url) => Expanded(
          child: SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: () => onOpen(url),
              icon: Icon(icon, size: 17),
              label: Text(label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                foregroundColor: fg,
                side: BorderSide(color: side),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        );

    return Row(
      children: [
        btn(Icons.record_voice_over_rounded, '四六级查询', kCetUrl),
        const SizedBox(width: 10),
        btn(Icons.computer_rounded, '计算机等级', kNcreUrl),
      ],
    );
  }
}
