/// 学校公告（独立于消息中心，数据源为教务处通知公告）
class SchoolNotice {
  final String id;
  final String title;
  final String date;
  final String url;
  final bool hasContent;
  final int views; // 浏览数（取自教务处公告页显示值）

  const SchoolNotice({
    required this.id,
    required this.title,
    required this.date,
    required this.url,
    this.hasContent = false,
    this.views = 0,
  });

  factory SchoolNotice.fromJson(Map<String, dynamic> json) {
    return SchoolNotice(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      hasContent: json['has_content'] == true,
      views: (json['views'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date,
        'url': url,
        'has_content': hasContent,
        'views': views,
      };
}
