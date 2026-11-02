import 'package:flutter/material.dart';

import '../../services/control_service.dart';
import '../../theme/app_theme.dart';

class MyResourceUploadsPage extends StatefulWidget {
  const MyResourceUploadsPage({super.key});

  @override
  State<MyResourceUploadsPage> createState() => _MyResourceUploadsPageState();
}

class _MyResourceUploadsPageState extends State<MyResourceUploadsPage> {
  bool _loading = true;
  String? _error;
  int _contributions = 0;
  int _downloads = 0;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final data = await ControlService.fetchMyUploads();
    if (!mounted) return;
    if (data == null) {
      setState(() {
        _loading = false;
        _error = '无法连接资源服务：可能无网络或尚未登录';
      });
      return;
    }
    final stats = data['stats'];
    final items = data['items'];
    setState(() {
      _contributions =
          stats is Map ? (stats['contributions'] as num?)?.toInt() ?? 0 : 0;
      _downloads =
          stats is Map ? (stats['downloads'] as num?)?.toInt() ?? 0 : 0;
      _items = items is List
          ? items
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : const [];
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: isDark ? context.scaffoldColor : Colors.white,
      appBar: AppBar(
        title: const Text('我的上传',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!,
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    children: [
                      Row(
                        children: [
                          _stat('贡献数', _contributions),
                          const SizedBox(width: 10),
                          _stat('下载量', _downloads),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 60),
                          child: Center(
                            child: Text('还没有上传记录',
                                style: TextStyle(
                                    fontSize: AppTheme.fontSmall,
                                    color: context.textTertiary)),
                          ),
                        )
                      else
                        for (final item in _items) ...[
                          _uploadCard(item),
                          const SizedBox(height: 10),
                        ],
                    ],
                  ),
                ),
    );
  }

  Widget _stat(String label, int value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: AppTheme.radiusMdAll,
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          children: [
            Text('$value',
                style: const TextStyle(
                    fontSize: 21, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          ],
        ),
      ),
    );
  }

  Widget _uploadCard(Map<String, dynamic> item) {
    final status = (item['status'] ?? '').toString();
    final files = item['files'];
    final fileList = files is List
        ? files.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    final area = _areaLabel((item['area'] ?? '').toString());
    final reviewNote = (item['reviewNote'] ?? '').toString().trim();
    final note = (item['note'] ?? '').toString().trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: AppTheme.radiusMdAll,
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (item['courseName'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600),
                ),
              ),
              _statusPill(status),
            ],
          ),
          if ((item['bookName'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                (item['bookName'] ?? '').toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textSecondary),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            '$area · ${(item['createdAt'] ?? '').toString()}',
            style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
          ),
          if (fileList.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final f in fileList)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '${_kindLabel((f['area'] ?? '').toString())} · '
                  '${(f['name'] ?? '').toString()} · '
                  '${_fmtBytes((f['size'] as num?)?.toInt() ?? 0)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, color: context.textSecondary),
                ),
              ),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('备注：$note',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textSecondary)),
          ],
          if (status == 'rejected' && reviewNote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('拒绝原因：$reviewNote',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _statusPill(String status) {
    final (text, color) = switch (status) {
      'approved' => ('已通过', Colors.green),
      'rejected' => ('已拒绝', Theme.of(context).colorScheme.error),
      _ => ('待审核', Colors.orange),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(fontSize: AppTheme.fontCaption, color: color)),
    );
  }

  String _areaLabel(String area) => switch (area) {
        'textbook' => '教材 PDF',
        'exam' => '试卷 + 答案',
        'exam_paper' => '试卷',
        'answer' => '答案',
        _ => area,
      };

  String _kindLabel(String kind) => switch (kind) {
        'textbook' => '教材',
        'exam_paper' => '试卷',
        'answer' => '答案',
        _ => kind,
      };

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }
}
