import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/campus_info_crawler.dart';

/// 「讲座与学术」「奖学金与资助」两栏的解析回归。
///
/// 夹具取自 2026-11-24 的真实页面原文（只保留两条，去掉导航与页脚）。
/// 为什么值得为两栏各写一条：二级站点的模板是本模块历史上最容易静默失效的
/// 地方 —— 页面一改版，`fetchList` 只会安静地返回空列表，用户看到的是
/// 「这个栏目没有消息」，而没有任何报错。
void main() {
  group('校园资讯 · 新栏目解析', () {
    test('讲座与学术（xsdt）走 main 模板，日期取「日 + 年-月」两段', () {
      final items = CampusInfoCrawler.debugParse(
        'main',
        _xsdtHtml,
        'https://www.cwxu.edu.cn',
      );
      expect(items.length, 2);
      expect(
        items.first.title.contains('鼎新大讲堂第8期'),
        isTrue,
        reason: '标题应该吃 `<h2>`（main 模板的 _pickTitle 顺序）',
      );
      expect(items.first.date, '2026-11-23');
      expect(
        items.first.url,
        'https://www.cwxu.edu.cn/info/1037/21909.htm',
        reason: '相对路径 ../ 必须被 resolve 成绝对地址',
      );
      expect(items[1].date, '2026-11-17');
    });

    test('奖学金与资助（zzgl）走 xgc 模板，无年份日期按「晚于今天算去年」推断', () {
      final items = CampusInfoCrawler.debugParse(
        'xgc',
        _zzglHtml,
        'https://xgc.cwxu.edu.cn',
      );
      expect(items.length, 2);
      expect(
        items.first.title.contains('云天教育奖助学金'),
        isTrue,
        reason: '标题要取 class="tit" 那个链接，不是「详细」那个',
      );
      // 夹具是 11 月 11 日；无论测试跑在哪一年，都不能推出未来日期
      final d = DateTime.parse(items.first.date);
      expect(d.month, 11);
      expect(d.day, 11);
      expect(
        d.isAfter(DateTime.now().add(const Duration(days: 1))),
        isFalse,
        reason: '无年份日期必须落在过去或今天，否则排序会把它顶到最前',
      );
      expect(items.first.url.startsWith('https://xgc.cwxu.edu.cn/'), isTrue);
    });

    test('两栏都已在栏目清单登记（避免只加一边导致 assert 崩）', () {
      expect(CampusInfoCrawler.columnById('xsdt'), isNotNull);
      expect(CampusInfoCrawler.columnById('zzgl'), isNotNull);
      expect(CampusInfoCrawler.columnById('xsdt')!.name, '讲座与学术');
      expect(CampusInfoCrawler.columnById('zzgl')!.name, '奖学金与资助');
      expect(CampusInfoCrawler.columnById('xsdt')!.kind, 'main');
      expect(CampusInfoCrawler.columnById('zzgl')!.kind, 'xgc');
    });
  });
}

/// 2026-11-24 抓自 https://www.cwxu.edu.cn/index/xsdt1.htm
const String _xsdtHtml = r'''<ul><li>
            <div class="time">
                <p>23</p>
                <p>2026-11</p>
            </div>
            <a href="../info/1037/21909.htm" target="_blank" title="鼎新大讲堂第8期——AI4Science：从化学大模型到具身智能机器人化学家">
                <h2>鼎新大讲堂第8期——AI4Science：从化学大模型到具身智能机器人化学家</h2>
                <p>主题：AI4Science：从化学大模型到具身智能机器人化学家主讲嘉宾：何晓主持人：钱杰书时间：2026年12月1日（周二）15:40报告地点：行政楼121会议室参会人员：全校师生嘉宾简介：何晓，教授，2003年、2006年分获南京大学学士和硕士学位，2010年获美国佛罗里达大学博士学位。2011年入职华东师范大学，2015年破格晋升教授，2023年晋升二级教授。现任安庆师范大学双聘学术副校长、上海市分子智造前沿科学研究基地副主任、中国化学会...</p>
            </a>
        </li><li>
            <div class="time">
                <p>17</p>
                <p>2026-11</p>
            </div>
            <a href="../info/1037/21855.htm" target="_blank" title="明湖人才·科技沙龙第88期——国家自然科学基金申报经验交流与分享">
                <h2>明湖人才·科技沙龙第88期——国家自然科学基金申报经验交流与分享</h2>
                <p>主题：国家自然科学基金申报经验交流与分享主讲嘉宾：刘诚（江南大学，教授）主持人：毛明轩时间：2026年11月20日下午14:00报告地点：行政楼121参会人员：全校师生嘉宾简介：刘诚，教授，江南大学，江南大学光电信息与物理科学学院教授，主要从事光学成像与检测、近场光学、生物医学光子学等研究，先后在韩国延世大学、新加坡国立大学、韩国光州科技研究院、英国谢菲尔德大学开展科研工作，回国后受聘于中科院上海光机所和江南...</p>
            </a>
        </li></ul>''';

/// 2026-11-24 抓自 https://xgc.cwxu.edu.cn/xszz1/tzgg.htm
const String _zzglHtml = r'''<ul><li>
                    <div class="list_time fl">
                        <p class="day">11</p>
                        <p class="month">Nov</p>
                    </div>
                    <div class="list_wen fr">
                        <a href="../content.jsp?urltype=news.NewsContentUrl&wbtreeid=1110&wbnewsid=3347" class="tit" target="_blank">关于开展2026年“云天教育奖助学金”评审工作的通知</a>
                        <p>各学院：为激励学生勤奋学习，江苏云天教育科技股份有限公司出资在我校设立“云天教育奖助学金”，用于表彰学业及综合素质优秀的学生现将有关事项通知如下：一、评选对...[<a href="../content.jsp?urltype=news.NewsContentUrl&wbtreeid=1110&wbnewsid=3347">详细</a>]</p>
                    </div>
                </li><li>
                    <div class="list_time fl">
                        <p class="day">11</p>
                        <p class="month">Nov</p>
                    </div>
                    <div class="list_wen fr">
                        <a href="../content.jsp?urltype=news.NewsContentUrl&wbtreeid=1110&wbnewsid=3346" class="tit" target="_blank">关于开展2026年“村田奖学金”评审工作的通知</a>
                        <p>​一、总则村田奖学金是指由无锡村田电子有限公司、村田新能源（无锡）有限公司出资设立，用于奖励我校全面发展的优秀普通本科学生、团队和班集体的专项奖学金。根据《...[<a href="../content.jsp?urltype=news.NewsContentUrl&wbtreeid=1110&wbnewsid=3346">详细</a>]</p>
                    </div>
                </li></ul>''';
