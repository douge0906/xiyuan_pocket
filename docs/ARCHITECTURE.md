# 架构说明

> 一页纸，给要改这个项目的人。先读 [README](../README.md) 了解功能，再读这里了解结构。
> 最后更新：2026-11-22（对应 `1.0.10+36`；Flutter 3.29.3 / Dart 3.7.2）

## 一句话架构

**客户端为主。** 课表、成绩、考试、待办等数据都在设备上获取与处理，
账号密码只存本机 secure storage，退出登录即清除。

自建服务端只承担 5 类事情：版本更新、公告、校历、试卷题库、资源中心。
**学校数据一条都不经过服务端**，所以服务器挂了核心功能照用。

## 规模

| 项 | 数字 |
|---|---|
| `lib/` | 191 个 dart 文件 / 66,487 行 |
| `test/` | 97 个 dart 文件 / 11,318 行 / **687 个用例**（`flutter test` 实跑输出；别用 grep 数 `test(` 静态数，会漏循环里生成的） |
| `android/` | 14 个 `.kt`（其中 9 个在 `widget/` 下，负责桌面小组件） |
| 平台 | 仅 Android（**没有 `ios/` 目录**） |

## 分层

| 层 | 目录 | 文件数 | 职责 | 改动风险 |
|---|---|---|---|---|
| 入口 | `main.dart`、`app.dart` | 2 | 启动、底部导航、主题装配、深链路由 | 低 |
| 页面 | `pages/` | 59 | 界面与交互（30 个顶层页 + `tools/` 18 个工具页 + `home/` `message/` `course/` `invite/` `user/` 共 11 个部件） | 中 |
| 组件 | `widgets/` | 27 | 可复用 UI（课表网格、余额卡、设置行、语音球…） | 低 |
| 服务 | `services/` | 86 | 本地存储、通知、登录闸门、退出清数据 | 中 |
| **学校对接** | `services/campus/` | 17 | **全部抓取实现**（CAS / 教务 / 一卡通 / 公告 / 资讯） | **高**（学校一改版就会坏） |
| 消息 | `services/sources/` | 4 | 一个容器 + 多个源（教务处 / 校园资讯 / 控制台公告） | 中 |
| 模型 | `models/` | 9 | 数据结构 | 低 |
| 状态 | `providers/` | 4 | Riverpod（课表 / 成绩 / 邀请 / 用户配置） | 中 |

`services/` 顶层 60 个 + 子目录 `campus/`(17) `sources/`(4) `ocr/`(2) `pdf/`(2) `labs/`(1) = 86。

## 改 X 要动 Y（对照表）

| 想做的事 | 要动的地方 |
|---|---|
| **加一个服务页工具** | ① `services/service_catalog.dart` 加一条 `ToolModel` ② `services/tool_navigator.dart` 加 `case`（需登录的还要加进 `loginRequired`） ③ 新建页面 |
| **改配色 / 字号** | `theme/app_theme.dart`（594 行）。⚠️ 但很多页面有硬编码颜色与字号（见「已知债务」），只改 theme 不会全局生效 |
| **加一个消息来源** | 在 `services/sources/` 新建一个 `MessageSource` 实现，再到 `services/message_channel_service.dart` 注册渠道；抓取逻辑放 `services/campus/` |
| **发版改版本号** | **只改一处**：`pubspec.yaml` 的 `version:`（连 `+N` 一起改）。Android 侧由 Gradle 自动取，App 内由 `package_info_plus` 运行时读（不手写副本） |
| **加一个本地缓存** | 抄 `services/textbook_storage.dart`（47 行，结构最简单，且带空列表守卫） |
| **改课表周次 / 单双周判定** | `models/course_model.dart` 的 `occursOn` / `isActiveOnWeek`（**已有测试覆盖**） |
| **改教材展示** | `pages/tools/textbook_page.dart`（按学期分组在 `_buildGroupedBooks`） |
| **改桌面小组件** | Dart 侧 `services/widget_sync_service.dart` + `services/widget_prefs.dart`；Kotlin 侧 `android/app/src/main/kotlin/.../widget/` |

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
   `test/textbook_storage_test.dart` 与 `test/exam_storage_test.dart` 已锁定这条，**改这两个文件时测试会保护你**。

2. **登录闸门只有一处** —— 进页面前用 `AuthGate.ensureLoggedIn`；提示文案统一取
   `AuthGate.loginRequiredMessage`。不要在页面里另写一套未登录提示。

3. **门面方法必须包 `{'data': …}`** —— `ApiService.fetchXxx` 返回 `{'data': ...}`，
   页面读 `resp['data']['xxx']`。漏包会表现为「查询成功但列表恒为空」。

4. **内置种子快照** —— `assets/seed/app_seed.json` 提供首屏内容（公告/资讯），
   由 `services/seed_data.dart` 翻译成新档案格式写进本地档案，之后联网刷新覆盖。

5. **不要按中文名猜教务路径** —— 正方各模块的目录/文件名与中文名**毫无关系**
   （例：「教材预订」在 `xsxk/tjxkyzb_cxXkResultTjxkYzb.html`，与"教材"二字无关）。
   **要用户提供真实 URL，不要猜。**

6. **报错直接展示 `$emsg`** —— 不要按异常文案做字符串匹配分情况（文案一改就静默失效）。

7. **`AppTheme.primaryColor` 是 getter 不是 `const`** —— 主题色可运行时变化，
   所以它不能用在 `const` 上下文里，用了会编译失败。

## 数据流

```
用户输入账密
  → CasClient 登录（拿到会话 cookie，失效时自动重登一次）
  → services/campus/* 抓取（课表 / 成绩 / 考试 / 教材 / 一卡通 / 公告 / 资讯）
  → 解析成模型 → Storage 写本地缓存（记住守卫）
  → Provider / setState → 页面展示
```

消息页走另一条：`MessageSource`（教务处 / 校园资讯 / 控制台公告）
→ `MessageRepository` → `MessageArchive` 归档 → 页面。四个源共用同一套
列表、已读、搜索与详情容器，**不各自做一套页面**。

## 构建与发布

- 工具链：**Flutter 3.29.3 / Dart 3.7.2**、JDK 21、Android SDK 35、`minSdk 21`、只出 `arm64-v8a`
- 本机 Flutter 在 `C:/Users/20616/WorkBuddy/tools/flutter_3293`，**不保证在 PATH 上**
- 日常构建：`flutter pub get` → `flutter analyze lib test` → `flutter test`
- **打包发版不要手敲 `flutter build apk`**，用 `xiyuan_ops/build_pocket.py`：
  它按年份/版本重命名产物、做 AAPT 校验、落到 `C:/build_ws/delivery/`
- 分发链路：本机签出 APK → 上传 CDN `static.wxxydouge.icu`（文件名必须带版本号，
  CDN 缓存一年）→ 控制端 `/api/v1/app/release` 下发版本信息 → App 内检查更新
- CI（`.github/workflows/ci.yml`）：push 到 `main` / `master` / `work/**` / `feat/**`
  与 PR 都会跑 `flutter analyze lib test` + `flutter test`；只有 main/master 才构建 APK

## 已知债务（改之前先知道）

| 项 | 现状 | 建议 |
|---|---|---|
| **硬编码样式** | `Color(0xFF…)` **337 处 / 49 个文件**；`fontSize:` **711 处** | 别一次性重构（风险高）。**新代码用 `AppTheme`**，老代码改到时顺手收 |
| **大文件** | `pages/course_table_home_page.dart` **3114 行**、`pages/tools/course_table_settings_page.dart` 1534 行、`services/campus/sygl_client.dart` 1417 行、`services/course_storage.dart` 1278 行 | 改动时优先小步、只动必要部分 |
| **依赖版本锁死** | `package_info_plus` / `home_widget` / `pointycastle` / 两个 `third_party/` fork | 原因写在 `pubspec.yaml` 注释里，**升级前先读注释**，别直接改版本号 |
| **法务文本是占位** | `assets/legal/privacy_policy.md`、`user_agreement.md` 都标着「占位版本」 | 定稿后整份替换，别在别处引用其中的条款措辞 |
| **校园资讯部分失效** | 学校官网改版：主站通知公告 404、要闻/快讯与学工处改为 JS 动态渲染，静态抓取拿不到 | 抓取实现集中在 `services/campus/campus_info_crawler.dart`（387 行），改这里 |
| **`pubspec.yaml` 注释漂移** | 多处注释仍写「本项目 Flutter 3.24.3 / Dart 3.5.3」，实际是 3.29.3 / 3.7.2 | 下次动到那个文件时顺手更，单独改没意义 |

## 相关文档

- [README](../README.md) —— 功能列表、安装、构建
- [docs/README](README.md) —— 本目录索引
- [docs/settings-ia-1.0.9.md](settings-ia-1.0.9.md) —— 设置页信息架构（改造依据）
- `../xiyuan_ops/`（不在本仓库）—— 规则源 `AGENTS.md`、现状 `STATE.md`、流程图 `FLOW.md`
