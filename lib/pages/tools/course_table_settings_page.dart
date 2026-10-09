import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/course_storage.dart';
import '../../theme/app_theme.dart';
import '../user/user_cards.dart';

/// 课表设置页（v1.1.0）：显示开关（网格线 / 非本周课程 / 背景图）+ 课程管理。
///
/// UI **复刻在线版**：顶部提示条 + 每行带副标题 + 章节名一致。
///
/// 入口：课表页右上角**齿轮**（取代原来的「三个点」菜单）。
/// 具体动作由课表页通过回调转发，避免两处各写一套「清空/同步」逻辑。
class CourseTableSettingsPage extends StatefulWidget {
  const CourseTableSettingsPage({
    super.key,
    required this.onAddCourse,
    required this.onEditTime,
    required this.onSyncTodos,
    required this.onClearAll,
  });

  /// 添加课程（课表页弹添加表单）。
  final VoidCallback onAddCourse;

  /// 调整上课时间（课表页的时间编辑弹窗）。
  final VoidCallback onEditTime;

  /// 同步今日课程到待办。
  final VoidCallback onSyncTodos;

  /// 清空全部课程（课表页内部会二次确认）。
  final VoidCallback onClearAll;

  @override
  State<CourseTableSettingsPage> createState() =>
      _CourseTableSettingsPageState();
}

class _CourseTableSettingsPageState extends State<CourseTableSettingsPage> {
  Map<String, dynamic> _display = CourseStorage.defaultDisplaySettings();

  /// 读取显示设置的 Future 缓存：v1.1.1 修复「开关先显示默认(true)、
  /// 读完存储再跳成实际值」的闪烁（用户反馈像抖动）。
  Future<Map<String, dynamic>>? _future;

  bool get _showGridLines => _display['showGridLines'] != false;
  bool get _showOtherWeeks => _display['showOtherWeeks'] == true;
  String get _bgPath => (_display['backgroundImage'] ?? '').toString();
  bool get _hasBg => _bgPath.isNotEmpty && File(_bgPath).existsSync();

  /// 「进入 App 自动更新课表」。缺字段时按默认开（老用户升级上来不会突然变关）。
  bool get _autoUpdateOnLaunch => _display['autoUpdateOnLaunch'] != false;

  @override
  void initState() {
    super.initState();
    _future = CourseStorage.loadDisplaySettings();
  }

  Future<void> _set(String key, Object value) async {
    final next = <String, dynamic>{..._display, key: value};
    setState(() {
      _display = next;
      // 立即把 Future 指向内存值：避免 FutureBuilder 重建时回读存储造成抖动
      _future = Future<Map<String, dynamic>>.value(next);
    });
    await CourseStorage.saveDisplaySettings(next);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
      ));
  }

  /// 选一张图作为课表背景（与在线版同一套逻辑）。
  ///
  /// image_picker 返回的是**临时缓存路径**，系统随时可能清掉，直接存会导致
  /// 背景图「过几天就丢」→ 这里把图片拷贝到应用文档目录持久化。
  Future<void> _pickBackground() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final ext = picked.path.contains('.')
          ? picked.path.split('.').last.toLowerCase()
          : 'jpg';
      final safe = ['jpg', 'jpeg', 'png', 'webp'].contains(ext) ? ext : 'jpg';
      final target = File('${docs.path}/course_background.$safe');
      // 换图时清掉旧后缀残留（旧图 png 新图 jpg 之类）
      for (final e in ['jpg', 'jpeg', 'png', 'webp']) {
        final old = File('${docs.path}/course_background.$e');
        if (await old.exists()) await old.delete();
      }
      await picked.saveTo(target.path);
      await _set('backgroundImage', target.path);
      _toast('背景图已设置，返回课表即可看到');
    } catch (_) {
      _toast('设置失败，请重试');
    }
  }

  /// 清除背景图：同时删掉文档目录里的图片文件。
  Future<void> _clearBackground() async {
    final p = _bgPath;
    await _set('backgroundImage', '');
    if (p.isNotEmpty) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _toast('已清除背景图');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('课表设置',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
          }
          // 用已加载的值渲染，避免开关先显示默认值再跳变（用户反馈的抖动）
          _display = snap.data!;
          return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // 顶部提示条（复刻在线版）
          userCard(
            context,
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: AppTheme.primaryColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '所有修改即时保存，返回课表自动刷新生效',
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.primaryColor),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('显示'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _switchTile(
                  icon: Icons.grid_on_rounded,
                  title: '显示网格线',
                  subtitle: '在课表格子与每天之间画出贯穿的分隔线',
                  value: _showGridLines,
                  onChanged: (v) => _set('showGridLines', v),
                ),
                Divider(height: 1, color: context.borderColor),
                _switchTile(
                  icon: Icons.calendar_view_week_rounded,
                  title: '显示非本周课程',
                  subtitle: '把「不在当前周」的课也画出来（淡化显示），方便看全貌',
                  value: _showOtherWeeks,
                  onChanged: (v) => _set('showOtherWeeks', v),
                ),
                Divider(height: 1, color: context.borderColor),
                _imageTile(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('同步'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _switchTile(
                  icon: Icons.sync_rounded,
                  title: '进入 App 自动更新课表',
                  subtitle: '打开 App 时自动从教务系统同步一次；关掉后可用课表页右上角的刷新键手动同步',
                  value: _autoUpdateOnLaunch,
                  onChanged: (v) => _set('autoUpdateOnLaunch', v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('课程'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _actionTile(
                  icon: Icons.add_circle_outline_rounded,
                  title: '添加课程',
                  subtitle: '手动添加没导入到的课，可设单双周与节数',
                  // v1.1.1：不再自动返回课表（用户反馈「点设置就跳回主页」很突兀）
                  onTap: widget.onAddCourse,
                ),
                Divider(height: 1, color: context.borderColor),
                _actionTile(
                  icon: Icons.schedule_rounded,
                  title: '调整上课时间',
                  subtitle: '修改每节课的开始 / 结束时间，作用于整张课表',
                  onTap: widget.onEditTime,
                ),
                Divider(height: 1, color: context.borderColor),
                _actionTile(
                  icon: Icons.playlist_add_check_rounded,
                  title: '同步今日课程到待办',
                  subtitle: '把今天的课一次性写进待办清单',
                  onTap: widget.onSyncTodos,
                ),
                Divider(height: 1, color: context.borderColor),
                _actionTile(
                  icon: Icons.delete_sweep_rounded,
                  title: '清空全部课程',
                  subtitle: '删除课表里的所有课程（不可恢复）',
                  danger: true,
                  onTap: widget.onClearAll,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '上课提醒在课表页右上角的铃铛 · 同步课表在课表页右上角的刷新键',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.textTertiary),
          ),
        ],
      );
        },
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.textSecondary)),
      );

  /// 开关行（复刻在线版：左图标 + 标题 + 副标题 + 右侧开关）。
  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style:
                          TextStyle(fontSize: 14, color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeColor: Colors.white,
                activeTrackColor: AppTheme.primaryColor,
              ),
            ),
          ],
        ),
      );

  /// 背景图行（复刻在线版：缩略图 + 清除 / 更换按钮）。
  Widget _imageTile() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.wallpaper_rounded, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('课表背景图',
                      style:
                          TextStyle(fontSize: 14, color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    _hasBg ? '已设置（点右侧可更换）' : '选一张本地图片作为课表底图',
                    style:
                        TextStyle(fontSize: 12, color: context.textTertiary),
                  ),
                ],
              ),
            ),
            if (_hasBg)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(_bgPath),
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            if (_hasBg)
              IconButton(
                tooltip: '清除背景图',
                icon: const Icon(Icons.close_rounded,
                    size: 18, color: Color(0xFF9CA3AF)),
                onPressed: _clearBackground,
              ),
            IconButton(
              tooltip: '选择图片',
              icon: const Icon(Icons.add_photo_alternate_outlined,
                  size: 20, color: Color(0xFF9CA3AF)),
              onPressed: _pickBackground,
            ),
          ],
        ),
      );

  /// 操作行（复刻在线版：左图标 + 标题 + 副标题 + 右箭头）。
  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: danger ? AppTheme.danger : AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontSize: 14,
                          color: danger
                              ? AppTheme.danger
                              : context.textPrimary,
                        )),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: context.textTertiary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: context.textTertiary),
            ],
          ),
        ),
      );
}
