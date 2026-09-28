# 架构说明

> 一页纸，给要改这个项目的人。先读 [README](../README.md) 了解功能，再读这里了解结构。
> 最后更新：2026-09-27

## 一句话架构

**纯客户端，没有服务器。** App 在设备上直接与学校系统通信（统一认证 CAS / 正方教务 / 融合门户 / 学院官网），
账号密码只存本机 secure storage，不经过任何第三方服务。

## 分层

| 层 | 目录 | 职责 | 改动风险 |
|---|---|---|---|
| 入口 | `main.dart`、`app.dart` | 启动、底部导航、主题装配 | 低 |
| 页面 | `pages/` | 界面与交互（首页/课表/消息/我的 + `tools/` 5 个工具页） | 中 |
| 组件 | `widgets/` | 可复用 UI（课表网格、余额卡、站点链接…） | 低 |
| 服务 | `services/` | 本地存储、通知、登录闸门、退出清数据 | 中 |
| **学校对接** | `services/campus/` | **全部抓取实现**（CAS/教务/一卡通/公告/资讯） | **高**（学校一改版就会坏） |
| 模型 | `models/` | 数据结构 | 低 |
| 状态 | `providers/` | Riverpod（课表/成绩/用户配置） | 中 |

## 改 X 要动 Y（对照表）

| 想做的事 | 要动的地方 |
|---|---|
| **加一个服务页工具** | ① `pages/toolbox_page.dart` 加条目 ② `services/tool_navigator.dart` 加 case（需登录的还要加进 `loginRequired`） ③ 新建页面 |
| **改配色 / 字号** | `theme/app_theme.dart`。⚠️ 但很多页面有硬编码颜色与字号（见「已知债务」），只改 theme 不会全局生效 |
| **加一个消息来源** | `services/campus/` 下新增抓取 + 在消息页注册；参考 `campus_info_crawler.dart` |
| **发版改版本号** | **只改一处**：`pubspec.yaml` 的 `version:`。Android 侧由 Gradle 自动取，App 内由 `package_info_plus` 运行时读（不手写副本） |
| **加一个本地缓存** | 抄 `services/textbook_storage.dart`（结构最简单，且带空列表守卫） |
| **改课表周次/单双周判定** | `models/course_model.dart` 的 `occursOn` / `isActiveOnWeek`（**已有测试覆盖**） |
| **改教材展示** | `pages/tools/textbook_page.dart`（按学期分组在 `_buildGroupedBooks`） |

## 关键约定（违反会出 bug）

1. **缓存守卫铁律** —— 抓取失败时会返回空，**空列表绝不能覆盖已有缓存**：
   ```dart
   static Future<void> saveXxx(List items) async {
     if (items.isEmpty) return;   // ← 必须有
     ...
   }
   ```
   这条在本项目**踩过 5 次**（公告列表、课表合并、教材、考试…），是最高频 bug 模式：
   *失败 → 静默返回空 → 空被当有效结果写回 → 抹掉好东西*。
   `test/` 下已有测试锁定教材与考试两处，**改这两个文件时测试会保护你**。

2. **登录闸门只有一处** —— 进页面前用 `AuthGate.ensureLoggedIn`；提示文案统一取
   `AuthGate.loginRequiredMessage`。不要在页面里另写一套未登录提示。

3. **门面方法必须包 `{'data': …}`** —— `ApiService.fetchXxx` 返回 `{'data': ...}`，
   页面读 `resp['data']['xxx']`。漏包会表现为「查询成功但列表恒为空」。

4. **内置种子快照** —— `assets/seed/app_seed.json` 提供首屏内容（公告/资讯），
   由 `services/seed_data.dart` 写进各 Service 的同名缓存键，之后联网刷新覆盖。

5. **不要按中文名猜教务路径** —— 正方各模块的目录/文件名与中文名**毫无关系**
   （例：「教材预订」在 `xsxk/tjxkyzb_cxXkResultTjxkYzb.html`，与"教材"二字无关）。
   **要用户提供真实 URL，不要猜。**

6. **报错直接展示 `$emsg`** —— 不要按异常文案做字符串匹配分情况（文案一改就静默失效）。

## 数据流

```
用户输入账密
  → CasClient 登录（拿到会话 cookie，失效时自动重登一次）
  → services/campus/* 抓取（课表 / 成绩 / 考试 / 教材 / 一卡通 / 公告 / 资讯）
  → 解析成模型 → Storage 写本地缓存（记住守卫）
  → Provider / setState → 页面展示
```

## 构建与发布

- 锁定 **Flutter 3.24.3 / Dart 3.5.3**（机器上若装了别的 Flutter，构建前要把它顶到 PATH 最前）
- 命令见 [README](../README.md)；**版本号只改 `pubspec.yaml` 一处**
- 分发：**不自建服务器/CDN**，APK 由 GitHub Actions 构建后在 Actions 页面的 Artifacts 里下载
- CI（`.github/workflows/ci.yml`）：每次 push 跑 `flutter analyze lib` + `flutter test`，
  测试通过后自动构建 release APK 并上传产物
  ⚠️ `flutter analyze` 的 `--fatal-infos` **默认为 on**，任何 info 级 lint 都会让 CI 变红

## 已知债务（改之前先知道）

| 项 | 现状 | 建议 |
|---|---|---|
| **硬编码样式** | `Color(0xFF…)` **269 处 / 34 个文件**；字号 **230+ 处、12 种以上取值** | 别一次性重构（风险高）。**新代码用 `AppTheme`**，老代码改到时顺手收 |
| **大文件** | `notification_page.dart` 1034 行、`course_table_home_page.dart` 934 行 | 改动时优先小步、只动必要部分 |
| **测试偏少** | 2026-09-27 起补了「缓存守卫 + 考试倒计时」（22 个用例），其余仍待补 | 优先给纯逻辑加（不依赖网络的） |
| **校园资讯部分失效** | 学校官网改版：主站通知公告 404、要闻/快讯与学工处改为 JS 动态渲染，静态抓取拿不到 | 见 `docs/ARCHITECTURE-message-unify.md` |
| **消息系统两套实现** | `school_notice_*` 与 `campus_info_*` 结构对称（各一套 service + 详情页） | 统一方案已备好但**尚未实施**，见上述文档 |
