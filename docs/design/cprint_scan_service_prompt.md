# 服务新增提示词 · 联创云打印「扫描件」（可直接复制给另一个对话）

> 这份文档本身就是提示词。**把下面「提示词正文」整段复制给另一个对话**即可开工；
> 不需要再补任何上下文，所有接口、字段、文件落点、验收标准都已实测写死。

---

## 提示词正文（从这里开始复制）

### 你的任务

在掌上锡院（Flutter App，仓库 `C:/build_ws/xiyuan_pocket`，包名 `xiyuan_pocket`）里新增一个服务项 **「云打印扫描件」**。

这个服务对应学校「联创云打印」系统（杭州联创）的 **扫描件** 功能：打印店代扫上传的 PDF / 图片，用户可以查看列表、下载、批量删除。原始页面是
`http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/scanDoc.html`。

**这是一个纯客户端功能**：学校数据一条都不经过本应用的自建服务端（`docs/ARCHITECTURE.md:8-12` 明确写了这条边界）。App 直接连学校站点。

### 必须先读这些文件（不要凭记忆写 API）

| 目的 | 文件 |
| --- | --- |
| 分层与七条约定 | `docs/ARCHITECTURE.md`（尤其 :23-36 分层表、:38-49「改 X 要动 Y」、:51-80 七条约定、:105-119 构建说明） |
| 主题与设计令牌 | `lib/theme/app_theme.dart`（594 行，唯一主题文件；`primaryColor` 是 **getter**，不能 const） |
| 会话与请求 | `lib/services/campus/campus_session.dart`（383 行） |
| 统一认证登录 | `lib/services/campus/cas_client.dart` |
| WebVPN 网关 | `lib/services/campus/webvpn.dart` |
| 网络模式探测 | `lib/services/net_mode.dart` |
| 持久会话范式 | `lib/services/campus/campus_store.dart` |
| 缓存范式（空列表守卫） | `lib/services/textbook_storage.dart` |
| 可取消令牌 | `lib/services/cancel_token.dart`（28 行，**没有 `throwIfCancelled`**） |
| 凭据存储 | `lib/services/storage_service.dart`（`UserConfig`） |
| 页面骨架 | `lib/pages/tools/my_study_page.dart`、`lib/pages/tools/exam_query_page.dart` |
| PDF 预览 | `lib/pages/tools/resource_viewer_page.dart` |
| 工具注册 | `lib/services/service_catalog.dart`、`lib/services/tool_navigator.dart`、`lib/models/tool_model.dart` |
| 登录闸门 | `lib/services/auth_gate.dart` |
| 复用组件 | `lib/widgets/app_card.dart`、`state_views.dart`、`empty_state_art.dart`、`loading_overlay.dart`、`settings_rows.dart` |
| 视觉基准 | `docs/design/cprint_scan_mockup.html`、`docs/design/cprint_scan_01_list.png` |

### 一、站点实测契约（全部已实测，可直接信）

**网络事实**

- `zzwy.cwxu.edu.cn` 解析到 **10.1.72.17**（内网）。**该站 443 无监听**，`https://` 一律连不上 → 只能用 `http://zzwy.cwxu.edu.cn:9130`。
- 因此 `lib/services/campus/campus_session.dart:106-113` 的 `httpsOnlyExclusions` **必须**加上 `'zzwy.cwxu.edu.cn'`（否则 `CampusSession` 会把 `*.cwxu.edu.cn` 的 http 强升 https → `HandshakeException` → `CampusException('与学校系统的安全连接失败，请确认网络环境后重试')` → 功能 100% 不可用）。**这条已经改好了，不要重复改。**
- `kjyy.cwxu.edu.cn`（10.1.75.2）是统一认证中转 authcenter，`wxcas.cwxu.edu.cn`（218.90.181.101）是 CAS。
- WebVPN 网关 `https://webvpn.cwxu.edu.cn` 公网可达。

**接口清单（前缀只有 `/api` 一个有效）**

```
GET  /api/client/Auth/SSoPage?backurl=<url>      → 统一认证入口
GET  /api/client/Auth/SSOLogin?targetPageUrl=…&uniToken=…   → 302 到 UniEntry
GET  /api/client/Auth/UniEntry?SessionId=…&Func=BackUrl_<url> → 302 回目标页，下发 OSESSIONID
GET  /api/client/Auth/Check?timestamp=<ms>        → code:0 表示已登录
GET  /api/client/Auth/GetUserInfo                 → 同上
GET  /api/client/Auth/Logout?timestamp=<ms>       → 退出
GET  /api/client/Scan/Get?timestamp=<ms>           → 扫描件列表
GET  /api/client/Scan/Download?dwJobId=<id>       → 下载
POST /api/client/Scan/Del   body {"dwJobId":"<id>"}  contentType application/json  → 删除
```

**错误码语义（实测）**

| code | 含义 | 处理 |
| --- | --- | --- |
| `0` | 成功 | — |
| `4` | 无效会话，未登录（`{"message":"无效会话，未登录"}`） | 走重新授权流程 |
| `16777231` | 删除失败 | 提示「删除失败，请稍后重试」 |
| `33558534` | 凭据校验失败（「用户名或密码错误」/「您的密码输入有误」） | ⚠️ 这是 **`/api/client/Auth/UniLogin` 的红鲱鱼**，真链路不走它 |

**扫描件字段（站点原名）**

`dwJobId`、`dwSubmitTime`、`dwSubmitDate`、`szDisplayName`、`dwFileSize`、`dwStatus`、`x_doctype.{type,classtype}`。

**过期判定：`dwStatus & 256 != 0` = 已过期。** 过期项：文字色 `#9c9c9c`、标「(已过期)」、**没有勾选框**、**没有下载按钮**。

**派生规则（前端 `scanDoc.js` 算的，App 要复刻）**

- `x_doctype = Cprint.getDocType(szDisplayName)`：按扩展名映射 classtype —— `jpg/png/jpeg/dif → img`；`pdf → pdf`；`txt/xml/mht/mhtml/html/htm → txt`；`doc/docx/dotx/docm/wps/wpt/dot/dotm/odt/csv → word`；`xls/xslx/xlsx/xlsm/xlsb/ods → excel`；`ppt/pptx/pps/pptm/ppsm/potm/pot → ppt`；其余 `other`。`type` 取扩展名并截到 5 字。
- 文件名按屏宽截断（cutlen）：`<399→6`、`<499→10`、`<599→10`、`<799→12`、`<999→18`、`<1300→22`、否则 `24`；中文算 2 个字符。
- `x_sorttime = Number(dwSubmitDate + dwSubmitTime)` —— 排序键。
- 日期 `YYYY.MM.DD`（`dwSubmitDate` 形如 `20261125`），时间 `HH:MM:SS`。
- 大小：`<1024 → N B`；`<1048576 → N KB`；否则 `N MB`。

**⚠️ `Scan/Get` 的 `result` 可能是 `null`**（账号没有扫描件时）。**必须当空列表渲染**，不能当错误 —— 站点前端判的是 `(!redata.result) || (redata.result.length == 0)`。

### 二、鉴权链路（实测跑通，别自己另发明）

**统一认证换票**：`POST {casBase}/lyuapServer/v1/tickets/{TGT}`，form `{service}`，响应**顶层** `ticket` 字段（不是 `data.ticket`）。**同一个 TGT 可以反复换不同 service 的 ST** —— 实测用同一 TGT 连着做完两遍云打印 SSO 全链，也换过教务的 ST，全程没再碰密码和验证码。这是「不重复输入」的基础。

**云打印 SSO 六步（`/api/client/Auth/UniLogin` 是红鲱鱼，32 种 payload 全试过都失败）**

```
① GET /api/client/Auth/SSoPage?backurl=<回跳页 URL>
     → {"code":0,"result":"https://kjyy.cwxu.edu.cn/authcenter/toLoginPage?redirectUrl=…&targetPageUrl=<base64>"}
② GET 那个 toLoginPage（不跟跳）
     → 302 到 CAS，Location 里带 service=https://kjyy.cwxu.edu.cn/authcenter/doAuth/<随机 32 位 id>
     （这个 doAuth id 是 authcenter 现场生成的，不跟这一跳就永远拿不到）
③ 用 TGT 换这个 service 的 ST
④ GET service?ticket=ST（不跟跳）
     → 302 到 http://zzwy.cwxu.edu.cn:9130/api/client/Auth/SSOLogin?targetPageUrl=…&uniToken=…
⑤ GET 那个 SSOLogin —— uniToken 必需，targetPageUrl 可选
     → 302 到 /api/client/Auth/UniEntry?SessionId=…&Func=BackUrl_…
⑥ GET 那个 UniEntry —— SessionId 与 Func 都必需，少一个都 404
     → 下发 OSESSIONID，302 回目标页
⑦ GET /api/client/Auth/Check → code:0 才算真登录上了
```

- `uniToken` 是个 JWT（HS512 + GZIP）—— **只当不透明字符串透传，不要解析**。
- 最终凭据只有 **`OSESSIONID`**（实测只带 `OSESSIONID` 时 `Auth/Check` 也是 `code:0`）。`SESSIONID` 同值但可忽略。
- 服务端响应是 **UTF-8**（不是 GBK），`campus_session.dart` 的 `utf8.decode(bytes, allowMalformed: true)` 已经够用，**不需要任何 charset 兼容处理**。
- 服务端一次响应会发 **3 条独立的 `Set-Cookie` 行**（`SESSIONID=` / `OSESSIONID=` 清空 / `OSESSIONID=<值>`）。Dart 的 `HttpHeaders` 会把它们暴露成 3 个独立 header value，`CampusSession._captureCookies` 逐条解析是对的 —— **不要照 Python requests 的合并表现去改 Dart**。

**⚠️ 三个必须处理的实现陷阱**

1. **302 的 `Location` 可能是相对路径。** 实测 `SSOLogin → UniEntry` 那跳返回的是 `/api/client/Auth/UniEntry?SessionId=…&Func=…`（相对路径，没有域名）。直接把它丢给 `session.get()` 会报「No host」。
   **必须用 `CampusSession.nextHop(上一个请求的原始地址, location)` 解析**，不能自己拼。`campus_session.dart:309-310` 有这个纯函数。
   校内直连时 `SSOLogin` 的 Location 是相对路径；校外走网关时网关把它改写成了绝对 URL —— **两种情况都要能处理**。

2. **`kjyy.cwxu.edu.cn` 也必须在包装白名单里。** authcenter 是内网服务（10.1.75.2），校外不包装就连不上。实测把 `kjyy.cwxu.edu.cn` 加进包装名单后，校外全链依然跑通（`Auth/Check code=0`）。注意网关返回给 `toLoginPage` 的 Location 会被改写成像 `https://webvpn.cwxu.edu.cn/https/<hex>/lyuapServer/login?service=…` 这种形式，但 **`service` 参数里装的仍是原始内网地址**（`https://kjyy.cwxu.edu.cn/authcenter/doAuth/<id>`）—— 换 ST 时要用这个原始地址（和 `dorm_service.dart` 里「CAS 换 ST 时 service 必须保持原始内网地址」的注释一致）。

3. **`CAS 换 ST 的 service 与实际访问的地址是两件事。** 换票时 POST 给 CAS 的 `service` 必须是**原始内网地址**；至于访问时要不要过网关，交给 `CampusSession.urlRewrite` 逐跳决定，不要把 service 本身改成包装后的 URL。

**校外 WebVPN**

- 网关对**内网域名**的编码 = `hex(key) + hex(AES-128-CFB(host))`，`key == iv == 'wrdvpnisthebest!'`。实测网关自己给出的重定向与本地算出来逐字相同。
- `zzwy.cwxu.edu.cn` → `77726476706e69737468656265737421eaed568569337f486b468ca88d1b203b`
- 包装形状：`https://webvpn.cwxu.edu.cn/http-9130/<encHost>/<path>`（端口非默认用 `http-9130` 段）。
- **`lib/services/campus/webvpn.dart` 的 `needsWrap` 原本只认私网 IP，域名不触发包装** → 必须为「已授权的内网域名」开显式白名单（`zzwy.cwxu.edu.cn`、`kjyy.cwxu.edu.cn`）。**这条已经改好了。**
- 顺序：`CasClient.login` → `WebVpn.login(session, tgt)` → 再走 SSO 链。网关 cookie 与站点 cookie **必须落在同一个会话对象**里。
- 网关登录态一旦就位，网关返回的 302 Location 里指向内网的地址**已被网关自动重写** → 跟随跳转时不要自己再包装（否则会包成 `http-9130/http-9130/…`）。只有**主动请求内网域名**那一跳需要自己包装 —— 这正是 `CampusSession.urlRewrite` 的用法。

### 三、文件落点（照抄，别自己重新设计）

**新增 6 个文件**

| 文件 | 职责 |
| --- | --- |
| `lib/services/campus/cas_session_center.dart` | L1：统一认证 TGT 缓存（owner + TTL 2h）+ `stFor` 换票 |
| `lib/services/campus/cprint_session_store.dart` | L3：云打印站点会话 OSESSIONID 缓存（owner + TTL 45min） |
| `lib/services/campus/cprint_client.dart` | 云打印站点 API 封装 |
| `lib/services/campus/cprint_models.dart` | `CprintScanItem` / `CprintUserInfo` |
| `lib/services/campus/cprint_sso_service.dart` | SSO 六步编排（本提示词提供完整实现，直接用） |
| `lib/services/cprint_scan_storage.dart` | 列表快照缓存（SP，TTL 10min） |
| `lib/services/cprint_scan_downloader.dart` | 流式下载（dart:io HttpClient 直连） |
| `lib/pages/tools/cprint_scan_page.dart` | 列表页 |
| `lib/pages/tools/cprint_scan_detail_page.dart` | 详情 / 预览页 |

**修改 4 处现有文件**

| 文件 | 改什么 |
| --- | --- |
| `lib/services/campus/campus_session.dart:106-113` | `httpsOnlyExclusions` 加 `'zzwy.cwxu.edu.cn'`（**已完成**） |
| `lib/services/campus/webvpn.dart` | `needsWrap` 加内网域名白名单（**已完成**） |
| `lib/services/service_catalog.dart` | 加 `ToolModel(id:'cprint_scan', name:'云打印扫描件', icon: Icons.document_scanner_rounded, color: Color(0xFF1F2937), needsNetwork: true)` |
| `lib/services/tool_navigator.dart` | `loginRequired` 加 `'cprint_scan'`；`switch` 加 `case 'cprint_scan':` 推 `CprintScanPage`；import 该页 |
| `lib/services/data_wipe.dart` + `lib/pages/user_page.dart` | 退出登录时清 TGT 缓存与 OSESSIONID 缓存（挂 `DataWipe.wipeAll()`） |

### 四、API 契约（照抄，两个模块之间靠这个对齐）

```dart
// ---- lib/services/campus/cprint_client.dart ----
class CprintClient {
  static const String base = 'http://zzwy.cwxu.edu.cn:9130';
  static Future<List<CprintScanItem>> fetchScans(CampusSessionBase session);
  static Future<CprintUserInfo?> checkSession(CampusSessionBase session);
  static Future<void> deleteScan(CampusSessionBase session, String jobId);
  static String downloadUrlFor(String jobId);
}

class CprintException implements Exception {
  final String message;
  CprintException(this.message);
  @override String toString() => message;
}

// ---- lib/services/campus/cprint_session_store.dart ----
class CprintSessionStore {
  static const Duration ttl = Duration(minutes: 45);
  static Future<void> save({required String username, required Map<String,String> cookies});
  static Future<Map<String,String>?> loadFresh({required String username});
  static Future<void> clear();
}

// ---- lib/services/campus/cas_session_center.dart ----
class CasSessionCenter {
  static const Duration tgtTtl = Duration(hours: 2);
  static Future<String> ensureTgt({required String username, required String password});
  static Future<String?> stFor({required String tgt, required String service});
  static void clear();
}

// ---- lib/services/campus/cprint_models.dart ----
class CprintScanItem {
  final String jobId, displayName, docType, docClassType;
  final int fileSize;
  final String submitDate, submitTime;
  final int status;
  bool get isExpired => status & 256 != 0;
  int get sortTime => int.tryParse(submitDate + submitTime) ?? 0;
  String get displayDate;   // YYYY.MM.DD
  String get displayTime;   // HH:MM:SS
  String get displaySize;   // B / KB / MB
  factory CprintScanItem.fromJson(Map<String,dynamic> j);
  Map<String,dynamic> toJson();   // 必须与 fromJson 对称且可往返
}

class CprintUserInfo {
  final String logonName, trueName, handPhone, email;
  factory CprintUserInfo.fromJson(Map<String,dynamic> j);
}

// ---- lib/services/campus/cprint_sso_service.dart（Lead 提供，可直接用） ----
class CprintSsoService {
  static Future<CprintSsoResult> ensureCprintSession({
    required String username, required String password,
  });
}
class CprintSsoResult {
  final bool ok;
  final String? message;      // 中文失败原因，可直接展示
  final bool needsPassword;   // true = 本机没存密码，要弹一次输入框
  final String? sessionId;    // OSESSIONID
  final Map<String,String> cookies;
}
```

**页面层的调用姿势**

```dart
final cfg = await StorageService.loadUserConfig();
final r = await CprintSsoService.ensureCprintSession(
  username: cfg.username, password: cfg.password,   // password 可能是空串
);
if (!r.ok) {
  // r.needsPassword → 弹一次账号密码输入框
  // 否则 → 显示 r.message
}
final session = CampusSession();
session.importCookies(r.cookies);
final items = await CprintClient.fetchScans(session);
```

### 五、行为要求（这是「逻辑正确、闭环」的判定标准）

1. **账密复用，不重复输入。** `ensureTgt` 的 password **允许空串**：
   - TGT 缓存命中 → 直接返回，**完全不碰密码**；
   - 未命中且密码为空 → 抛 `CampusException('本机未保存密码，请先在「我的」登录一次后再用本功能')`；
   - 未命中且密码非空 → `CasClient.login` 一次并写入缓存。
   `ensureCprintSession` 捕获这个异常后返回 `needsPassword: true`，由页面弹一次输入框。**正常路径下用户永远看不到输入框。**

2. **三层会话，各管各的。**
   - L1 CAS TGT —— 身份，跨 service 通用，TTL 2h，落 secure storage。
   - L2 ST —— 单次、绑定单个 service，**不落盘**（用完即弃）。
   - L3 OSESSIONID —— 云打印站点会话，TTL 45min，落 secure storage。
   落盘统一用 `flutter_secure_storage`，照 `lib/services/campus/campus_store.dart` 的 `CampusStore` 写法（三键 + owner 校验 + TTL）。**owner 必须等于当前用户名**，否则不能复用。

3. **会话失效要能自愈。** `Scan/Get` 返回 `code:4` → 清掉 L3 缓存 → 走一次完整 SSO 重连 → 重试一次；再失败才报错。

4. **下载必须自己写流式下载。** ⚠️ `CampusSession.body` 是 **UTF-8 解码后的字符串**，用它下 PDF 会把二进制弄坏。必须用 `dart:io` 的 `HttpClient` 直连，手带 `Cookie: OSESSIONID=…` 头：
   - 落盘 `getApplicationDocumentsDirectory()/cprint_scan/`（App 私有目录；`AndroidManifest` **没有任何存储权限**，所以别写公共 Download 目录）；
   - 先写 `.part` 再 rename，避免半截文件；
   - 同名文件已存在就复用，不要重复下载；
   - `CancelToken` 只有 `isCancelled` / `addListener` / `removeListener` / `cancel()`，**没有 `throwIfCancelled`** —— 自己判 `if (cancelToken?.isCancelled ?? false) throw ...`，并在 `cancelToken.addListener(() => client.close(force: true))` 里断连接。
   - 出口只有 `share_plus`（全仓唯一文件分享出口）：`Share.shareXFiles([XFile(path)], text: name)`。**没有 open_filex / 文件 Intent 插件**。
   - PDF 预览复用 `lib/pages/tools/resource_viewer_page.dart`（`ResourceViewerPage({required title, required filePath})`，内部用 `flutter_pdfview`）。

5. **列表缓存要带空列表守卫。** `CprintScanStorage.save(items)` 在 `items.isEmpty` 时**直接 return 不写**（照 `lib/services/textbook_storage.dart:13-22` 的 `saveBooks`）—— 抓取失败时若照写会把已有内容覆盖成空。

6. **原页面 13 项功能必须 1:1 覆盖**：列表 / 单选 / 全选 / 已选计数 / 按 `sortTime` 排序（排序后计数归 0）/ 单项下载 / 批量下载 / 批量删除（**二次确认弹窗**）/ 未选时禁用并提示「请选择要删除的文件」/ 空态「没有扫描文档噢」/ 已过期项置灰（`#9c9c9c`、无勾选框、无下载按钮、标「(已过期)」）/ 底部批量操作栏滚动固定 / 登录态失效提示。
   **不做**：上传、打印、打印点、使用记录（站点其它 tab，不在本功能范围）。

7. **文案不要编造。** 站点只暴露 `dwStatus` 的位 256，**保留天数从未被接口暴露** → UI 里**不许写「保留 30 天后自动清理」**这类文案，只写「已过期，不可下载」。

8. **错误文案中文口语化、可直接展示**（照 `CampusException` 既有风格）。

### 六、工程约束

- **服务层不得 import 页面层**；页面 → services/campus 的导入方向照 `docs/ARCHITECTURE.md` 的六处既有写法。
- 不引入新依赖。
- 中文注释解释「为什么」，不是复述「做了什么」。
- **不要凭记忆写 API** —— 每个用到的类、方法、字段名都要先在源码里核对过。
- 改完跑 `flutter analyze lib test`，再跑 `flutter test`。
  ⚠️ 本机 Flutter 3.24.3 / Dart 3.5.3，项目要求 3.29.3 / 3.7.2；**用 3.24.3 跑 `flutter test` 会有 68 个既有失败**（全是 `Color.toARGB32`，Dart 3.7 才有的 API，失败点在 `lib/theme/app_theme.dart:338-339`、`lib/services/storage_service.dart:446/463`、`lib/services/widget_sync_service.dart:163/543` 等未触碰的文件）—— **与本次改动无关**，是既有基线问题。请用项目要求的 SDK 复跑。
  ⚠️ Flutter 3.24.3 的 `pub get` 会重写 `pubspec.lock`，跑完记得 `git checkout -- pubspec.lock`。
- `test/service_settings_render_test.dart:26-35` 断言 `mainServices` 的条目数 → 加了工具条目会被这个测试覆盖，**跑测试时留意它**。

### 七、验收清单

- [ ] 「云打印扫描件」出现在服务页，能点进列表页。
- [ ] 已登录统一认证后进页面，**全程不弹输入框、不走验证码**（TGT 命中即静默换票）。
- [ ] 校内直连：列表能拉到，顶部有网络模式提示。
- [ ] 校外 WebVPN：能通过网关拉到同一份列表。
- [ ] 列表项显示：类型图标、文件名（按屏宽截断）、`YYYY.MM.DD`、`HH:MM:SS`、大小、过期徽标。
- [ ] 已过期项：置灰、无勾选框、无下载按钮。
- [ ] 多选 / 全选 / 已选计数联动正确；排序后计数归 0。
- [ ] 单项下载、批量下载都能拿到**可正常打开**的 PDF/图片文件（验证二进制没被 UTF-8 破坏）。
- [ ] 批量删除有二次确认；删除成功后列表刷新。
- [ ] 账号无扫描件时显示空态「没有扫描文档噢」，**不是报错**。
- [ ] 会话失效（`code:4`）能自愈重连；重连失败给出可读提示。
- [ ] 退出登录后 TGT 与 OSESSIONID 缓存都被清掉。
- [ ] `flutter analyze` 无 issue。

### 八、参考素材

- 设计方案文档：`docs/design/cprint_scan_design.md`（715 行，含全部实测契约与交互逻辑章节）。
- 设计稿：`docs/design/cprint_scan_01_list.png`、`02_detail.png`、`03_states.png`、`04_auth.png`、`00_all.png`。
- 设计稿 HTML 源：`docs/design/cprint_scan_mockup.html`（单文件内联 CSS、零 CDN、16 个 390×844 机型框）—— 新页面的视觉直接照它。
- 实测脚本（Python + Dart 探针）在仓库外 `D:\workdsh\`：`cprint_sso_chain.py`、`cprint_contract.py`、`cprint_tgt_reuse.py`、`cprint_webvpn_chain.py`、`cprint_webvpn.py`、`probe_auth.py`；Dart 探针在 `tool/`。

---

## 提示词正文结束（复制到这里即可）

---

## 附：给开发者的补充说明

**为什么走统一认证而不是云打印自有账号**

云打印系统**有自己的密码库**。用统一认证口令调 `/api/client/Auth/Login`（它用 `PublicKey` 接口下发的 **1024-bit RSA + 每次变化的 nonceStr** 加密，格式是 `password + ";" + nonceStr`）返回 `code:33558534「用户名或密码错误」` —— 同一个口令在 CAS 侧能登录成功、在云打印侧失败，说明两边密码不同源。所以只能走统一认证换票。

**为什么 `UniLogin` 是红鲱鱼**

站点配置 `set_uniprint_changpassword_api=1`（注释写「这个配置项的作用是可以统一密码」）、`set_xinanzhengfa=0`，所以站点主流程本来就应该走 SSO。但站点前端源码里**根本找不到** `SSOLogin` / `UniEntry` 这两个地址 —— 浏览器会自动跟着 302 走，前端从来没需要显式写它们。`/api/client/Auth/UniLogin` 是服务端模板内置的另一个动作，32 种 payload 全试过、连会话都建好了它还是回「您的密码输入有误」。**别再往那个方向猜了。**

**为什么不用自己写 RSA**

App 现有的 `lib/services/campus/cas_client.dart` 的 `rawRsaEncrypt` 已经和 CAS 前端的加密算法**逐位等价**（两边对同一密码算出同一个 256 位十六进制整数），**不需要任何改动**。
