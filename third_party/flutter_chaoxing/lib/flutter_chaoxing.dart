/// 学习通（超星）协议客户端 —— 本地 fork。
///
/// 上游：[`flutter_chaoxing` 0.4.2](https://pub.dev/packages/flutter_chaoxing)
/// （Apache-2.0，作者 TsinbeiLabs，仓库 TsinbeiLabs/flutter_chaoxing）。
/// 上游是官方 Android 客户端 7.0.2 的逐字节移植，从这里反推：
/// 请求签名（inf_enc / cxsign / webRequestSign）、设备注册、passport2 登录、
/// 课堂签到、以及面向学生的数据接口。
///
/// ## 为什么要 fork（三条都是实测过的，不是推测）
///
/// 1. **Dart 版本**：上游 `environment: sdk: '>=3.9.0 <4.0.0'`，从 0.1.0 到 0.4.2
///    十四个版本一次都没放宽过。本项目用 Flutter 3.29.3 / Dart 3.7.2，直接
///    `pub get` 会解析失败。
/// 2. **依赖冲突**：上游要 `pointycastle: ^4.0.0`，本项目锁 3.9.1（见根 pubspec
///    注释：4.x 未验证）。不能让 WebVPN 的 AES-128-CFB 跟着升。
/// 3. **dev_dependencies**：上游的 `lints ^6.0.0` 自身要求 SDK >= 3.8.0，
///    即使改了主 SDK 约束也会在解析阶段失败。
///
/// ## 剪掉了什么（本任务只需要「作业 + 考试」）
///
/// - `chaoxing_sign_service.dart`（1367 行）：课堂签到、扫脸签到、
///   `CLIENT_FORM_SIGN` 桥、课程/班级列表。**Dart 3.7 不支持的 10 处
///   `'key': ?var` 空感知 map 元素也全在这个文件里** —— 删掉它之后
///   剩下的文件实测 0 处，所以本 fork **没有改动任何一行上游源码**。
/// - `chaoxing_captcha.dart`（897 行）：滑块验证码破解。删掉之后
///   `image` 依赖也不再需要。
/// - `chaoxing_user_agent.dart`（151 行）：只被注释引用。
///
/// 保留的 `ChaoxingApiService` 是完整的（含 notices / grades / knowledge /
/// live 等接口），因为它的传输层（`_getJson` / `_postFormSigned` /
/// `_handleResponse`）与 `fetchTaskFeed` 长在一起，拆开的收益低于风险。
library;

export 'src/chaoxing_api_service.dart';
export 'src/chaoxing_auth_service.dart';
export 'src/chaoxing_knowledge_models.dart';
export 'src/chaoxing_logger.dart';
export 'src/chaoxing_models.dart';
export 'src/chaoxing_sign_crypto.dart';
export 'src/chaoxing_sign_models.dart';
