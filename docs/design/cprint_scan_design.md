# 掌上锡院 · 联创云打印「扫描件」功能设计方案

> 目标站点：`http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/scanDoc.html`
> 归属系统：杭州联创云打印（cprintPc）｜锡院部署：图书馆技术部
> 文档版本：v1.0（2026-11-24）｜依据：站点前端源码逐行反查 + 138 条路由实测 + 网关编码实测
> 配套设计稿：`docs/design/cprint_scan_01_list.png`、`cprint_scan_02_detail.png`、`cprint_scan_03_states.png`、`cprint_scan_04_auth.png`、`cprint_scan_00_all.png`（HTML 源：`cprint_scan_mockup.html`，渲染脚本：`render_cprint_scan.py`）

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| 功能本质 | 云打印系统里「扫描件」列表（打印店代扫上传的 PDF/图片），支持**下载、删除、批量操作**，有过期概念 |
| 鉴权真相 | 云打印**有自己的账号密码库**（`Auth/Login` 拒绝统一认证口令），但站点 `set_xinanzhengfa=0` + `set_uniprint_changpassword_api=1` ⇒ 正确姿势是**统一认证 SSO 换出 `OSESSIONID`**。实测：用户给的 `25350103 / 778899clcc.0QWE` **在统一认证与云打印两侧都可用**，端到端链路已跑通 |
| SSO 落点 | `GET /api/client/Auth/SSoPage?backurl=…` → `kjyy.cwxu.edu.cn/authcenter`（CAS service）→ 回跳 `SSOLogin?uniToken=…` → **GET `SSOLogin`**（`uniToken` 必需）→ 302 → **GET `UniEntry`**（`SessionId` + `Func=BackUrl_<url>` 必需）→ `Set-Cookie: OSESSIONID` |
| 校外可行性 | ✅ **已实测跑通**（2026-11-25 `cprint_webvpn_chain.py`：网关下发 ticket → `zzwy.cwxu.edu.cn` 被包装成 `http-9130/<encHost>/…` → SSO → `Auth/Check code=0` → `Scan/Get` 正常）。前提仍是**先 `WebVpn.login()` 拿到网关登录态**，否则网关一律 302 回 `/login`。详见 §2.3 |
| 账密复用 | ✅ **一次 CAS 登录拿到的 TGT 可反复换任意 service 的 ST**（实测同一 TGT 换 `authcenter/doAuth/<id>` 与 `jwgl.cwxu.edu.cn/sso/lyiotlogin` 均成功；TGT 自包含，CAS 登录响应不下发 `Set-Cookie`）。落地形态 = 新增「统一认证会话中心」缓存 TGT（owner=学号）：命中 ⇒ 静默换票，**全程不弹输入框、不做验证码**；未命中 ⇒ 用本机 secure storage 里的密码兜底登录一次（`rememberPassword=false` 时密码为空串，此时才弹一次输入框）。详见 §2.4 |
| App 侧需改的现有代码 | ① `campus_session.dart` 的 `httpsOnlyExclusions` 加 `zzwy.cwxu.edu.cn`（该站 443 不通，**不改则 100% 不可用**，已实测复现 `HandshakeException`）② `webvpn.dart` 增加「显式域名包装」开关（现 `needsWrap` 只认私网 IP，域名不触发） |
| 落地形态 | 双通道：**A 直连 API（首选）** + **B WebView 承载（兜底）**，二者共用同一套状态机与 UI |
| 未闭环项 | **无**。SSO 契约已闭环并用 App 真实 `CasClient` + `CampusSession` 跑通（见 §1.4）。剩余待办是**落地实现**，不再是接口调研 |

> ⚠️ 2026-11-25 更新：本表与 §1.4、§4 的结论在当天被实测推翻并重写。旧的「PASSERROR / USERLOCK / UniLogin 未闭环」结论**全部作废**，根因见 §1.4。

---

## 1. 站点实测契约（全部经真实 HTTP 验证）

### 1.1 网络事实

| 名称 | DNS | 端口 | 说明 |
|---|---|---|---|
| `zzwy.cwxu.edu.cn` | **10.1.72.17（内网）** | 9130 | 云打印主站；**443 不通，只能 http** |
| `kjyy.cwxu.edu.cn` | 10.1.75.2（内网） | 443 | 统一认证前置 `authcenter`（CAS service） |
| `wxcas.cwxu.edu.cn` | 218.90.181.101（公网） | 443 | 学校统一身份认证（App 已有 `CasClient.casBase`） |
| `webvpn.cwxu.edu.cn` | 公网 | 443 | 深澜 Srun 网关（校外入口） |

校内直连已验证可用（带 Host 头打内网 IP 返回 `200 {"code":4,…}`，即路由通、只是没会话）。

### 1.2 接口清单（前缀唯一为 `/api`）

> 实测 69 个动作名 × 2 种前缀共 138 条路径，**只有 7 条非 404**；`/uniPrint`、`/api/v1`、`/cprintPc` 等前缀变体全部 404。

| 用途 | 方法 | 路径 | 关键入参 | 返回 / 备注 |
|---|---|---|---|---|
| 列表 | GET | `/api/client/Scan/Get` | `timestamp=<rand>` | `{code:0, result:[ScanItem…]}`；未登录 `{"code":4,"message":"无效会话，未登录"}` |
| 下载 | GET | `/api/client/Scan/Download` | `dwJobId=<id>` | 二进制流（站点前端用 `download` 属性） |
| 删除 | POST | `/api/client/Scan/Del` | JSON `{"dwJobId":"…"}` | `Content-Type: application/json` |
| 判活 | GET/POST | `/api/client/Auth/Check` | — | `{code:0, result:{szTrueName,szLogonName,szHandPhone,szEmail}, SessionId}`；**必须带 Content-Length，否则 411** |
| 用户信息 | GET/POST | `/api/client/Auth/GetUserInfo` | — | 同上（带尾斜杠也 200） |
| **SSO 入口** | GET | `/api/client/Auth/SSoPage` | `backurl=<页面URL>`（**query 参数**） | `{code:0, result:"https://kjyy.cwxu.edu.cn/authcenter/toLoginPage?redirectUrl=…&targetPageUrl=<base64>"}` |
| **SSO 回调①** | GET | `/api/client/Auth/SSOLogin` | `uniToken=<JWT>`（**必需**）、`targetPageUrl=<base64>`（可选） | 302 → `Location: /api/client/Auth/UniEntry?SessionId=<32hex>&Func=BackUrl_<目标URL>`；`Set-Cookie: SESSIONID=<32hex>` |
| **SSO 回调②** | GET | `/api/client/Auth/UniEntry` | `SessionId=<32hex>`（必需）+ `Func=BackUrl_<目标URL>`（必需） | 302 → `Location: <目标页>`；`Set-Cookie: OSESSIONID=<32hex>`（先发一条 `OSESSIONID=; expires=1970` 再发真值） |
| ⚠️ 红鲱鱼 | POST | `/api/client/Auth/UniLogin` | — | **不是有效回调**。任何 payload 都返回 `{"SessionId":null,"code":33558534,"message":"您的密码输入有误"}`（即使会话已建立也一样）。见 §4 |
| 自有密码登录 | POST | `/api/client/Auth/Login` | `{szLogonName, szPassword, szToken}` | `szPassword` = base64(RSA_PKCS1(密码 + ";" + nonce))，1024-bit 动态公钥 |
| 令牌 | POST | `/api/client/Auth/GetAuthToken` | — | `{code:0, szToken, szAuthType}` |
| 公钥 | GET | `/api/client/Auth/PublicKey` | — | `{code:0, result:{publicKey, nonceStr}}`（nonce 每次变） |
| 扫码轮询 | GET | `/api/client/Auth/WaitUserIn` | — | 扫码成功后服务端代持密码再调 `Login` |
| 退出 | GET | `/api/client/Auth/Logout` | `timestamp` | — |

**关键错误码语义**

| code | 出现位置 | 含义 |
|---|---|---|
| `4` | Check / Scan.Get | 无效会话，未登录 → 需要重登 |
| `33558534` | Login / UniLogin | 凭据校验失败（`Login`=用户名或密码错误；`UniLogin`=您的密码输入有误——**UniLogin 是个死胡同，别再猜字段**） |
| `16777228` / `0x100000C` | 站点 URL errorCode | 「云打印系统内没有您的账号信息，请联系图书馆技术部处理」（`set_errormsg`） |
| `16777231` | Scan/Del | 删除失败（实测用伪 `dwJobId` 触发） |

### 1.3 扫描件数据模型（前端 `scanDoc.html` 模板 `scan-template`）

| 字段 | 含义 | App 侧处理 |
|---|---|---|
| `dwJobId` | 任务主键 | 下载/删除入参 |
| `szDisplayName` | 原文件名 | 标题（前端按屏宽截断：<399→6 / <499→10 / <599→10 / <799→12 / <999→18 / <1300→22 / else 24 字 + 类型后缀） |
| `x_doctype.type` | 文档类型（前端由文件名推导） | 副标题 + 类型徽标 |
| `x_doctype.classtype` | 图标类名 | 图标 |
| `dwFileSize` | 字节数 | B / KB / MB 三级格式化 |
| `dwSubmitDate` + `dwSubmitTime` | 提交日期 + 时间 | `2024.01.02` + `10:30`；排序键 `x_sorttime = Number(date+time)` |
| `dwStatus` | 状态位 | **`dwStatus & 256 != 0` ⇒ 已过期**（前端 `{{if ($value.dwStatus & 256) == 0}}`，过期项置灰 #9c9c9c、无勾选框、无下载按钮） |

> ⚠️ `x_doctype` 是**前端派生字段**，接口只回 `szDisplayName`。App 需复刻 `Cprint.getDocType()` 的推导规则（按扩展名/关键字分类），否则图标与类型文案缺失。

### 1.4 测试账号实测结果（2026-11-25 重写：端到端链路已跑通）

账号 `25350103` / 密码 `778899clcc.0QWE` **在统一认证与云打印两侧都可用**。用 App 真实 `CasClient` + 真实 `CampusSession` 跑完整链路，全部绿灯：

```
CAS login: status=ok note=登录成功（第 1 次尝试）
TGT = TGT-112030-764584058d714e6eaa82d62f24ddbb89
SSoPage status=200
  result = https://kjyy.cwxu.edu.cn/authcenter/toLoginPage?redirectUrl=…&targetPageUrl=aHR0cDovL3p6d3ku…
  targetPageUrl(decoded) = http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/scanDoc.html?sessionId=6d1dc983076245f0a3e54ebb4bc30b15
authcenter 302 -> https://wxcas.cwxu.edu.cn/lyuapServer/login?service=https%3A%2F%2Fkjyy.cwxu.edu.cn%2Fauthcenter%2FdoAuth%2Fc54120fd2f6148c8b834e56af5b92501
service = https://kjyy.cwxu.edu.cn/authcenter/doAuth/c54120fd2f6148c8b834e56af5b92501
ST = ST-112030-c797484d638f4173858cb72c9e6e06e0
doAuth 302 -> http://zzwy.cwxu.edu.cn:9130/api/client/Auth/SSOLogin?targetPageUrl=…&uniToken=…
SSOLogin status=302
  location -> http://zzwy.cwxu.edu.cn:9130/api/client/Auth/UniEntry?SessionId=6d1dc983…&Func=BackUrl_http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/scanDoc.html
  cookies -> {OSESSIONID: 6d1dc983…, SESSIONID: 6d1dc983…}
UniEntry status=302
  location -> http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/scanDoc.html
  cookies -> {SESSIONID: 6d1dc983…, OSESSIONID: 6d1dc983…}
Auth/Check status=200
  code = 0  szLogonName = 25350103  szTrueName = 车雷
Scan/Get status=200 body={"code":0,"message":"","result":null}
```

> `Scan/Get` 的 `result` 是 **`null`**（不是 `[]`）——该账号名下没有扫描件。站点前端 `cprint_scanDoc.js:169` 判的是 `(!redata.result) || (redata.result.length == 0)`，**App 侧必须把 `null` 当空列表渲染，不能当错误**。

#### 关键修正：之前「凭据被拒」的结论是**我方探针的 bug**，不是学校的问题

| 曾经的结论 | 实情 |
|---|---|
| CAS 返回 `PASSERROR`「密码错」 | ❌ 假警报。根因：我的 Python 探针 `probe_auth.parse_rsa()` 用 `re.findall(r"'([0-9a-f]{64})'", src)` 从 App 源码里抓 modulus，只匹配到**两段 64 hex**，把 **258 hex 的 CAS modulus 截断成 128 hex** → 用错 modulus 加密 → 密文是垃圾 → CAS 只能回「密码错」。修复后 Python 密文与浏览器抓包**逐字节相同** |
| `NOUSER` = 学号不存在、`PASSERROR` = 口令不符（三路错误码判别） | ⚠️ 现象是真的（`CODEFALSE`=验证码错 / `NOUSER`=学号不存在 确实成立），但**「PASSERROR 只能解释为口令不符」是错的**——请求侧缺陷也会得到 PASSERROR |
| 云打印自有登录「用户名或密码错误」 | ✅ 真的。`Auth/Login` 走的是云打印**自己的**密码库，与统一认证口令不同源 ⇒ 这条路彻底不可用 |
| App 的 `cas_client.dart` 需要补 `loginusertoken` / `logintoken` 头 | ❌ 不需要。补与不补都能登录成功（`header_ablation.py` 实测：只发 Referer/Origin/Content-Type 即可换出 `tgt`+`ticket`）。那两个头只是 CAS 前端 axios 拦截器的产物 |
| App 的 `cas_client.dart` 需要改 captcha 流程 | ❌ 不需要。现行「`GET /lyuapServer/kaptcha` → 识别 → 用同一响应里的 uid 提交」就是对的 |
| 账号被锁 `USERLOCK` | ❌ 假警报，同一 modulus bug 的产物 |

**仍然成立的结论**（这些是真问题，与上述无关）：

1. **App 侧 `CasClient` 与 `CasClient.rawRsaEncrypt` 完全正确，无需任何改动**（已用线上 `app.js` 自带的私钥解密浏览器抓包密文，比对出同一个明文）。
2. **云打印 `Auth/Login` 这条路不可用**（独立密码库），必须走 SSO。
3. **`zzwy.cwxu.edu.cn` 没有 443 监听** → 必须加进 `httpsOnlyExclusions`，否则 `CampusSession` 会把 http 强升 https 并抛 `HandshakeException`。**这是落地前唯一的硬性前置改动**（已实测复现）。
4. `szTrueName` 等中文字段是 **UTF-8**（响应头 `charset=utf-8`，原始字节 `e8 bda6 e9 9b b7` = U+8F66 U+96F7），**不需要 GBK 兼容处理**；`campus_session.dart:290` 的 `utf8.decode(bytes, allowMalformed: true)` 已足够。
5. **服务端一次响应发 3 条独立 `Set-Cookie` 行**（`SESSIONID=` 空值 / `OSESSIONID=` 过期 / `OSESSIONID=<真值>`）。已用真实 Dart `HttpClient` 实证：`HttpHeaders.forEach` 把它们暴露为 **3 个独立 header value**，`_captureCookies` 逐条解析后得到正确的 `OSESSIONID` ⇒ **cookie 逻辑无需改动**（注意：Python `requests` 的 cookiejar 会把它们显示成逗号串，不要照它的表现改 Dart 代码）。

#### 验收方式

凭据已确认可用，**§8.2 的验收清单可以按计划直接执行**（「校外 WebVPN」那一条也已在 2026-11-25 用 `cprint_webvpn_chain.py` 实测跑通，见 §2.3）。

---

## 2. 鉴权链路设计（App 侧）

### 2.1 总体链路

```
┌─ 掌上锡院 App ────────────────────────────────────────────────┐
│ ① CAS 登录（复用 CasClient）                                   │
│    GET  wxcas/lyuapServer/kaptcha → 识别算式                    │
│    POST wxcas/lyuapServer/v1/tickets  {username,password(RSA),  │
│         service,id,code} → TGT                                │
│ ② 取 SSoPage                                                   │
│    GET  zzwy:9130/api/client/Auth/SSoPage?backurl=<scanDoc>   │
│    → result = kjyy/authcenter/toLoginPage?redirectUrl=…        │
│                &targetPageUrl=base64(scanDoc.html?sessionId=X) │
│ ③ 取 authcenter 的 CAS service（doAuth 路由参数每次随机）        │
│    GET  kjyy/authcenter/toLoginPage…  (校外需经 WebVPN 包装)     │
│    → 302 Location: wxcas/lyuapServer/login?service=             │
│        https://kjyy.cwxu.edu.cn/authcenter/doAuth/<32hex>       │
│ ④ TGT 换 ST                                                    │
│    POST wxcas/lyuapServer/v1/tickets/<TGT>  form{service=③}     │
│    → ST-xxxx                                                    │
│ ⑤ 用 ST 打通 authcenter                                        │
│    GET  kjyy/authcenter/doAuth/<id>?ticket=ST-xxxx           │
│    → 302 → zzwy:9130/api/client/Auth/SSOLogin?               │
│               targetPageUrl=<base64>&uniToken=<JWT>           │
│      ★ uniToken 是 authcenter 签发给云打印的「已认证凭证」       │
│ ⑥ 换云打印会话（两个 GET，必须按序）                              │
│    GET  zzwy:9130/api/client/Auth/SSOLogin?uniToken=<JWT>     │
│    → 302 Location: /api/client/Auth/UniEntry                  │
│                     ?SessionId=<32hex>                        │
│                     &Func=BackUrl_<目标URL>                    │
│    → Set-Cookie: SESSIONID=<32hex>                            │
│    GET  zzwy:9130/api/client/Auth/UniEntry?SessionId=…&Func=… │
│    → 302 Location: <目标页>                                    │
│    → Set-Cookie: OSESSIONID=<32hex>   ★ 真正的凭据              │
│ ⑦ 之后所有 /api/client/Scan/* 均带 OSESSIONID                  │
└───────────────────────────────────────────────────────────────┘
```

> **两个必答事实（实测消融得出）**：
> - `SSOLogin` 的 **`uniToken` 必需**（只带 `targetPageUrl` → 404）；`targetPageUrl` 可选。
> - `UniEntry` 的 **`SessionId` 与 `Func` 都必需**（只带 `SessionId` → 404）；`Func=BackUrl_<url>` 决定回跳目标，`Func=BackUrl_`（空 url）回跳 `/client/index.html`。
> - 实测只带 `OSESSIONID`（不带 `SESSIONID`）调 `Auth/Check` 也是 `code:0` ⇒ **OSESSIONID 才是真正的凭据**，`SESSIONID` 可忽略。
> 📌 上图 ①「CAS 登录」在 App 内可被 §2.4 的 **TGT 缓存**替换：缓存命中时整步跳过（不输密码、不做验证码）；未命中才用本机 secure storage 里的密码兜底登录一次。

> **⚠️ 实现时的三个陷阱（2026-11-25 实测后补）**
>
> 1. **302 的 `Location` 可能是相对路径。** 实测 `SSOLogin → UniEntry` 那跳返回的是 `/api/client/Auth/UniEntry?SessionId=…&Func=…`（没有域名），直接拿去请求会报「No host」。**必须用 `CampusSession.nextHop(上一个请求的原始地址, location)` 解析**（`campus_session.dart:309-310`，纯函数）。校内直连时是相对路径；校外走网关时网关会把它改写成绝对 URL —— **两种情况都要能处理**。
> 2. **`kjyy.cwxu.edu.cn` 也必须在包装白名单里。** authcenter 是内网服务（10.1.75.2），校外不包装就连不上。实测加进去后**校外全链依然跑通**（`Auth/Check code=0`）。
> 3. **换 ST 的 service 与实际访问地址是两件事。** 换票时 POST 给 CAS 的 `service` 必须是**原始内网地址**（`https://kjyy.cwxu.edu.cn/authcenter/doAuth/<id>`）；访问时要不要过网关，交给 `CampusSession.urlRewrite` 逐跳决定，**不要把 service 本身改成包装后的 URL**（与 `dorm_service.dart:195-207` 的注释一致）。

### 2.2 关键设计决策

| 决策 | 理由 |
|---|---|
| **不用云打印自有账号密码登录** | 实测 `Auth/Login` 返回「用户名或密码错误」——云打印有独立密码库；`set_uniprint_changpassword_api=1` 说明设计意图就是「统一密码」，用户只该用统一认证口令 |
| **不硬编码 `doAuth` 的 32 位随机 id** | 该 id 每次请求 `toLoginPage` 都不同；必须**先请求 `toLoginPage` 抓 302 Location** 再拿 service 去换 ST |
| **CAS 换票的 service 用原始内网地址** | 与 `dorm_service.dart:195-207` 同款：service 必须是平台注册原值；WebVPN 包装交给 `CampusSession.urlRewrite` 处理（逐跳跟随时网关已把回跳地址自动改写成包装 URL，只有主动请求内网域名那一跳才需自己包装，见 §2.3.2） |
| **云打印会话与教务会话彻底隔离** | `OSESSIONID` 与 `local_campus_session` 语义不同、生命周期不同；独立 `CampusSession` 实例 + 独立 cookie 仓，不写 `CampusStore` |
| **HTTP-only 站点**：把 `zzwy.cwxu.edu.cn` 加入 `httpsOnlyExclusions` | `campus_session.dart:240-245` 会把 `*.cwxu.edu.cn` 的 http 强升 https，而该站 443 不通（实测 curl https 返回 000）→ 不加白名单则**全站不可用**。**2026-11-25 已实测复现**：不改白名单时 App 真实链路抛 `CampusException('与学校系统的安全连接失败…')`；加上后同一脚本一次跑通 |
| **校内外双通道同源** | 校内直连 http；校外 WebVPN 包装后访问，**同一份代码只差 `urlRewrite` 与一次 `WebVpn.login()`** |

### 2.3 WebVPN 域名包装（**已实测跑通**）

深澜 Srun 的目标地址编码格式：

```
encHost(host) = hex(key) + hex(AES-128-CFB(host, key=iv="wrdvpnisthebest!"))
示例: wxcas.cwxu.edu.cn → 77726476706e69737468656265737421e7ef429d347e6b47661dc7a99c406d3676
      zzwy.cwxu.edu.cn → 77726476706e69737468656265737421eaed568569337f486b468ca88d1b203b
      10.1.72.17         → 77726476706e69737468656265737421a1a70fcd69673a1e2f5f
URL 形态: https://webvpn.cwxu.edu.cn/{scheme[-port]}/{encHost}{path}?query
```

**验证方式**：抓网关自己 302 出的 `/https/<encHost(wxcas)>/lyuapServer/login?...`，用本机 openssl 复刻同一算法算 `wxcas.cwxu.edu.cn`，**密文逐字节一致**；再直接请求该包装 URL，返回 **200 + 真实 CAS 登录页 HTML** ⇒ 网关正确解包。

**必须先登录网关**：未登录时，任何包装 URL（含 zzwy 域名 / 内网 IP）一律 302 → `https://webvpn.cwxu.edu.cn/login` 并下发 `wengine_vpn_ticketwebvpn_cwxu_edu_cn` cookie。带上该 cookie 重试仍 302 ⇒ 不是格式问题，是缺登录态。

⇒ **校外顺序固定为**：CAS 登录 → `WebVpn.login(session, tgt)` → 用**同一个 session 对象**发包装后的请求（网关 cookie 就在这个 session 里）。

#### 2.3.1 校外 WebVPN 全链实测（2026-11-25，`cprint_webvpn_chain.py`）

```
CAS login -> TGT = TGT-142958-…
[1] gateway root -> 302   （下发 wengine_vpn_ticketwebvpn_cwxu_edu_cn）
[2] gateway ST = ST-142959-…   （service=https://webvpn.cwxu.edu.cn/login?cas_login=true）
[3] gateway login -> 302 Location=/wengine-vpn-token-login?token=…
[4] SSoPage code=0  -> https://kjyy.cwxu.edu.cn/authcenter/toLoginPage?…
[5] toLoginPage -> 302 -> https://wxcas.cwxu.edu.cn/lyuapServer/login?service=…doAuth%2F<id>
[6] ST for service = ST-143000-…
[7] doAuth -> 302 -> http://zzwy.cwxu.edu.cn:9130/api/client/Auth/SSOLogin?targetPageUrl=…&uniToken=…
[8] SSOLogin -> 302 Location=https://webvpn.cwxu.edu.cn/http-9130/77726476706e69737468656265737421eaed568569337f486b468ca88d1b203b/api/client/Auth/UniEntry?SessionId=…
[9] UniEntry -> 302 Location=https://webvpn.cwxu.edu.cn/http-9130/77726476706e69737468656265737421eaed…/client/new/cprintPc/scanDoc.html
[10] Auth/Check code=0 szLogonName=25350103 szTrueName=车雷
[11] Scan/Get body={"code":0,"message":"","result":null}
```

⇒ **包装形状确认**：目标端口非 80/443 时，网关用 `http-9130` 段承载，完整形态为
`https://webvpn.cwxu.edu.cn/http-9130/<encHost>/<path>`；`zzwy.cwxu.edu.cn` 的 encHost =
`77726476706e69737468656265737421eaed568569337f486b468ca88d1b203b`（与本节上表一致）。

**补实测（2026-11-25，`cprint_webvpn_chain_kjyy.py`）**：把 `kjyy.cwxu.edu.cn` 加入包装名单后重跑校外全链，
[1]→[11] 全绿，`Auth/Check code=0 szTrueName=车雷`。同时确认：网关给 `toLoginPage` 的 Location 虽被改写成
`https://webvpn.cwxu.edu.cn/https/<hex>/lyuapServer/login?service=…`，但 **`service` 参数里装的仍是原始内网地址**
`https://kjyy.cwxu.edu.cn/authcenter/doAuth/<id>` —— 换 ST 必须用它。
`https://webvpn.cwxu.edu.cn/http-9130/<encHost>/<path>`；`zzwy.cwxu.edu.cn` 的 encHost =
`77726476706e69737468656265737421eaed568569337f486b468ca88d1b203b`（与本节上表一致）。

#### 2.3.2 新发现：网关会自动把内网地址改写成包装 URL

看 [8][9] 两跳：网关登录态一旦就位，它 302 给出的 `Location` 里，指向内网的地址**已经是包装后的形式**
（`https://webvpn.cwxu.edu.cn/http-9130/<encHost>/…`），而不是原始内网域名。

⇒ 对 App 侧的直接含义：

1. `CampusSession` **逐跳跟随时不必自己再包装**内网域名（否则会二次包装成 `http-9130/http-9130/…`）。
2. 只有**主动请求**内网域名的那一跳需要自己包装（如第 4 步 `SSoPage`、第 7 步 `SSOLogin` 的 target）。
3. 实现上仍用 `urlRewrite` 的**显式域名白名单**兜底：白名单命中的域名一律包装，`webvpn.cwxu.edu.cn` 自身的 URL 放行不包装。

**App 侧需要的最小改动**（`lib/services/campus/webvpn.dart`）：

```dart
// 现状：needsWrap 只认私网 IP，域名一律 false → 对 zzwy.cwxu.edu.cn 不生效
static bool needsWrap(String url) { … }              // webvpn.dart:89-103
static String wrapUrl(String url) { … }               // webvpn.dart:108-120

// 建议：增加显式域名白名单，不改私网 IP 的既有判定
static String wrapUrl(String url, {Set<String> forcedHosts = const {}}) {
  if (!needsWrap(url) && !_forcedHost(url, forcedHosts)) return url;
  …
}
```

> 不要用「猜域名是不是内网」的方式放开包装；应由**业务显式声明**要访问的域名白名单，避免把公网地址也塞进网关导致链路异常。

### 2.4 统一认证会话复用（账密不重复输入）

#### 2.4.1 三层会话模型

| 层 | 凭据 | 作用域 | 有效期 | App 侧存放 |
|---|---|---|---|---|
| **L1** | `TGT`（CAS 服务端票据） | **跨 service 通用**：同一 TGT 可换任意 service 的 ST | 长（CAS 侧会话） | 新增 `CasSessionCenter` 缓存（owner=学号 + TTL） |
| **L2** | `ST`（单张服务票据 `ST-xxx`） | 只对换票时指定的 service 生效 | 极短（一次性跳转） | 内存，不落盘 |
| **L3** | `OSESSIONID`（云打印自己的会话 cookie） | 仅云打印站点 `/api/client/*` | 中（按 30~60min 缓存） | 新增 `CprintSessionStore` 缓存（owner=学号 + TTL） |

**三条实测结论（2026-11-25，直接引用，不再论证）**

1. **一次 CAS 登录拿到的 TGT 可以反复换任意 service 的 ST**。实测同一 TGT 换 `authcenter/doAuth/<id>` 与 `jwgl.cwxu.edu.cn/sso/lyiotlogin` **都成功**。
2. **TGT 是自包含凭据**：CAS 登录响应（`POST wxcas/lyuapServer/v1/tickets`）返回顶层 `{tgt, ticket}`，**不下发任何 `Set-Cookie`** ⇒ 不依赖 cookie jar 就能复用。
3. 实测脚本 `D:\\workdsh\\cprint_tgt_reuse.py`：**同一 TGT 连续两次跑完云打印 SSO 全链**（第二次 `Auth/Check` 仍 `code=0`、`Scan/Get` 正常），**第二次没有再输密码和验证码**。

#### 2.4.2 时序图

```
┌─ 掌上锡院 App ─────────────────────────────────────────────────────────┐
│ L1  CasSessionCenter（跨工具共享，owner=当前学号）                       │
│   ① TGT 缓存命中（owner == 当前学号 且 未过期）                          │
│      → 跳过 CAS 登录，直接进入 ③                                      │
│   ② 兜底：读 StorageService.loadUserConfig()                           │
│      ├─ password 非空（记住密码=开）→ 用本机密码做一次 CAS 登录          │
│      │    POST wxcas/lyuapServer/v1/tickets → {tgt, ticket}             │
│      │    → 写入 TGT 缓存（owner=当前学号）→ 回到 ③                     │
│      └─ password 为空串（记住密码=关）                                   │
│           → **仅此时弹一次账号密码输入框** → 登录成功后写入 TGT 缓存    │
│ L2  换票（每次、每个 service 各换一张，短命，不缓存）                    │
│   ③ POST wxcas/lyuapServer/v1/tickets/<TGT> form{service} → ST-xxx      │
│      service① = https://kjyy.cwxu.edu.cn/authcenter/doAuth/<32hex>     │
│      service② = https://jwgl.cwxu.edu.cn/sso/lyiotlogin（教务侧可复用）  │
│ L3  云打印会话（CprintSessionStore 缓存 OSESSIONID，owner + TTL 30~60min）│
│   ④ SSoPage → authcenter → ST → doAuth → SSOLogin?uniToken              │
│      → UniEntry?SessionId&Func → OSESSIONID                            │
│      → 写入 OSESSIONID 缓存（owner=当前学号）                           │
│   ⑤ 之后所有 /api/client/Scan/* 带 OSESSIONID                           │
│      命中缓存 ⇒ 跳过 ④；未命中 ⇒ 重跑 ④（换票用 L1 的 TGT，不需要密码） │
└─────────────────────────────────────────────────────────────────────────┘
```

#### 2.4.3 两条路径

| 路径 | 触发条件 | 动作 | 是否弹输入框 | 是否需要验证码 |
|---|---|---|---|---|
| **快路径** | TGT 缓存命中（owner == 当前学号 且未过期） | TGT → ST → SSO → OSESSIONID | ❌ 不弹 | ❌ 不要 |
| **兜底路径** | TGT 缺失 / 过期 / 换票失败 | 用本机 secure storage 里的密码做一次 CAS 登录 → 缓存 TGT → 回到快路径 | ✅ **仅当本机没存密码时弹一次** | ✅ 需要（CAS 算式验证码） |

> **归属人校验（防跨账号串台）**：TGT 缓存与 OSESSIONID 缓存都必须记录 **owner=当前学号**；读取时若 `owner != 当前学号` 一律**视为未命中并丢弃**（不尝试复用）。参照 `CampusStore.loadFreshSession`（`lib/services/campus/campus_store.dart:47-65`）的既有做法：既校验 owner，又校验 TTL。
>
> **App 现状（本次要改的点）**：TGT 目前**全仓不落盘**、内存用完即弃 —— `campus_store.dart:265`、`card_balance.dart:48`、`sygl_client.dart:105`、`webvpn.dart:129`、`dorm_service.dart:73-74` 全是局部变量。`DormService._ensureTgt`（`dorm_service.dart:676-685`）已有「优先复用缓存 TGT」的雏形，但只服务于电费充值一条链，且**进程一杀即失效**。
>
> **账密现状**：账号密码已在系统安全存储（`StorageService.loadUserConfig()`，`lib/services/storage_service.dart:78-113`，密码键 `secure_school_password`，仅 `rememberPassword=true` 时读取）。`rememberPassword=false` 时密码是**空串** ⇒ 此时才需要弹一次输入框，**不要每进一次工具就弹**。
>
> **退出登录必须一起清**：`lib/services/data_wipe.dart` 的 `DataWipe.wipeAll()`（`data_wipe.dart:26-66`）已清空 SharedPreferences + SecureStorage（`secure.deleteAll()`）并调 `DormService.clearToken()`（`data_wipe.dart:54`）——落盘部分会被顺带清掉；但**内存态必须显式清**（同 `user_page.dart:618` 的 `LocalCampusService.clear()` 做法），否则同一进程内切号后仍可能复用上一个账号的 TGT。
>
> **落地对应**：新增文件见 §5.1，改动文件见 §5.2，登录流程树见 §7.3。

---

## 3. 双通道方案

### 通道 A：直连 API（首选，Native 体验）

| 环节 | 实现 |
|---|---|
| 会话 | 独立 `CampusSession` 实例；`urlRewrite` 在校外时 = 带域名白名单的 WebVPN 包装器 |
| 登录 | 复用 `CasClient.login()` 拿 TGT → §2.1 的 ②~⑥ 步 |
| 列表 | `GET /api/client/Scan/Get?timestamp=<rand>` → 解析 `result[]` |
| 下载 | `GET /api/client/Scan/Download?dwJobId=<id>`，流式落盘 |
| 删除 | `POST /api/client/Scan/Del`，JSON `{"dwJobId":"…"}` |
| 失效 | 任一接口返回 `code == 4` ⇒ 会话失效 → 拉起登录授权流程（自动重登一次，仍失败则提示） |

**优点**：全 Native、离线可缓存、批量操作可控、与 App 现有 UI 一致。

### 通道 B：WebView 承载（兜底，A 不通时）

复用 `lib/pages/recharge_webview_page.dart:95-128` 的成熟套路：

1. 校外：先 `WebVpn.login()`，再把 `DormService.vpnCookies`（只含 `wengine_vpn_ticket*` / `show_*` / `heartbeat`）注入 WebView；
2. `loadRequest('http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/scanDoc.html')`；
3. 由站点自身 JS 完成 `thirdlogin` → authcenter → CAS → 回跳 → `SSOLogin` → `UniEntry` → `OSESSIONID`；
4. 用户在 H5 里操作，App 只提供「在 App 内打开 / 用外部浏览器打开」两个出口。

**优点**：不依赖任何未公开契约，站点改版也不用改 App。
**缺点**：体验割裂、无法复用 App 的批量/下载/分享能力。

**降级策略**：A 通道任一步失败时，页面顶部给出「**改用网页版打开**」按钮，而不是把用户卡死在错误页。

---

## 4. SSO 契约（已闭环，2026-11-25 实测）

> 旧版本这一章叫「未闭环点：`UniLogin` 入参」，穷举了 32+ 种 payload 全部失败。
> **结论是：`UniLogin` 根本不是这条链的回调端点，它是个红鲱鱼。** 真正的回调是两个 GET：`SSOLogin` → `UniEntry`。

### 4.1 真实链路（已跑通）

```
GET /api/client/Auth/SSoPage?backurl=<scanDoc.html>
  → result = https://kjyy.cwxu.edu.cn/authcenter/toLoginPage
                 ?redirectUrl=http://zzwy.cwxu.edu.cn:9130/api/client/Auth/SSOLogin
                 &targetPageUrl=base64(scanDoc.html?sessionId=<32hex>)

GET https://kjyy.cwxu.edu.cn/authcenter/toLoginPage?…
  → 302 Location: https://wxcas.cwxu.edu.cn/lyuapServer/login?service=https%3A%2F%2Fkjyy.cwxu.edu.cn%2Fauthcenter%2FdoAuth%2F<32hex>

POST https://wxcas.cwxu.edu.cn/lyuapServer/v1/tickets/<TGT>  form{service=https://kjyy.cwxu.edu.cn/authcenter/doAuth/<32hex>}
  → ST-xxxx

GET https://kjyy.cwxu.edu.cn/authcenter/doAuth/<32hex>?ticket=ST-xxxx
  → 302 Location: http://zzwy.cwxu.edu.cn:9130/api/client/Auth/SSOLogin?targetPageUrl=<base64>&uniToken=<JWT>

GET http://zzwy.cwxu.edu.cn:9130/api/client/Auth/SSOLogin?uniToken=<JWT>[&targetPageUrl=<base64>]
  → 302 Location: /api/client/Auth/UniEntry?SessionId=<32hex>&Func=BackUrl_<目标URL>
  → Set-Cookie: SESSIONID=<32hex>

GET http://zzwy.cwxu.edu.cn:9130/api/client/Auth/UniEntry?SessionId=<32hex>&Func=BackUrl_<目标URL>
  → 302 Location: <目标页>
  → Set-Cookie: OSESSIONID=<32hex>
```

### 4.2 参数消融结论（必答）

| 端点 | 必需参数 | 可选参数 | 无效组合的响应 |
|---|---|---|---|
| `SSOLogin` | **`uniToken`** | `targetPageUrl` | 无参数 / 只带 `targetPageUrl` → **404** |
| `UniEntry` | **`SessionId`** + **`Func`** | — | 只带 `SessionId` → **404**；`Func=BackUrl_`（空 url）→ 302 到 `/client/index.html` |

### 4.3 `uniToken` 是什么，App 要不要解析？

`uniToken` 是 authcenter 签发给云打印的 JWT（3 段，`{"alg":"HS512","calg":"GZIP"}`，payload 是 gzip 压缩的 base64 JSON，含 `loginName` / `iss:"unifound"` / `aud` 等）。

⇒ **App 侧不需要解析、不需要校验、不需要解密，只当不透明字符串原样透传即可。**

### 4.4 `UniLogin` 为什么是个红鲱鱼

`POST /api/client/Auth/UniLogin` 无论传什么（32+ 组合：JSON/form/明文/RSA 密文/`sessionId`/`uniToken`/`szLogonName`…）都返回：

```json
{"SessionId":null,"code":33558534,"message":"您的密码输入有误","result":null}
```

**即使会话已经建立也一样。** 站点前端源码（`scanDoc.html` / `common.js` / `login.js`）里也**没有** `UniLogin` 字面量——它是服务端模板内置的通用动作，与本条 SSO 链无关。**不要再花时间猜它的字段名。**

### 4.5 副作用：站点前端为什么自己跑得通？

站点 H5 的 `common.js` 会调 `SSoPage` 拿 `result` 并 `window.location.href = result`，浏览器随后完整走完 `toLoginPage → CAS → doAuth → SSOLogin → UniEntry`，**两个 302 跳转都由浏览器自动跟随**，所以前端代码里看不到这两个端点的字面量。App 直连时必须**手动**按序请求这两跳（`CampusSession` 手动跟跳转 + 保留 `Location`，正好适用）。

---

## 5. App 侧模块落点

### 5.1 新增文件

| 文件 | 职责 | 参照模板 |
|---|---|---|
| `lib/services/campus/cas_session_center.dart` | **统一认证会话中心（L1）**：TGT 缓存（owner=学号 + TTL）+ `stFor(service)` 换票 + `ensureTgt` 兜底（必要时才用本机密码登录一次） | `lib/services/dorm_service.dart:656-685`（`_stFor` / `_ensureTgt`）+ `lib/services/campus/campus_store.dart:36-65`（`CampusStore` 的 owner+TTL 落盘范式） |
| `lib/services/campus/cprint_session_store.dart` | **云打印会话缓存（L3）**：`OSESSIONID` 落盘（owner=学号 + TTL 30~60min），命中即免掉整条 SSO 链 | `lib/services/campus/campus_store.dart:36-65` |
| `lib/services/campus/cprint_client.dart` | **经 `CasSessionCenter` 换出 `OSESSIONID`**（自己不碰 TGT、不碰密码、不做验证码）+ Scan/Get/Download/Del 调用 + 错误归一 | `lib/services/campus/empty_classroom_fetcher.dart`（收 `CampusSessionBase`、不自造会话） |
| `lib/services/campus/cprint_models.dart` | `CprintScanItem`（含 `dwStatus & 256` 过期判定、`x_doctype` 派生） | `lib/services/campus/empty_classroom_fetcher.dart` 的 model + `fromJson` |
| `lib/services/cprint_scan_storage.dart` | 列表本地缓存（TTL），**必须带空列表守卫** | `lib/services/textbook_storage.dart:13-22` |
| `lib/services/cprint_scan_downloader.dart` | HttpClient 流式下载 → 私有目录 `.part` + rename | `lib/services/resource_download_service.dart:111-139`（但它只服务服务端资源，需自写） |
| `lib/pages/tools/cprint_scan_page.dart` | 列表页（选择/排序/批量/空态/错误态） | `lib/pages/tools/my_study_page.dart`、`exam_query_page.dart` |
| `lib/pages/tools/cprint_scan_detail_page.dart` | 详情/预览页 | `lib/pages/tools/resource_viewer_page.dart`（flutter_pdfview） |

### 5.2 修改文件（各 1~3 行）

| 文件:行 | 改动 |
|---|---|
| `lib/services/campus/campus_session.dart:106-108` | `httpsOnlyExclusions` 增加 `'zzwy.cwxu.edu.cn'` —— **已实测的硬性前置**：不改则 `CampusSession` 把 http 强升 https → `HandshakeException` → 「与学校系统的安全连接失败」，功能 100% 不可用（2026-11-25 已改并跑通） |
| `lib/services/campus/webvpn.dart:89-120` | `wrapUrl` 增加域名白名单参数（见 §2.3） |
| `lib/services/service_catalog.dart:8` | `mainServices` 增加一条 `ToolModel(id:'cprint_scan', name:'云打印扫描件', icon: Icons.document_scanner_rounded, color: Color(0xFF1F2937), needsNetwork:true)` |
| `lib/services/tool_navigator.dart:25-35` | `loginRequired` 增加 `'cprint_scan'` |
| `lib/services/tool_navigator.dart:55+` | `switch` 增加 `case 'cprint_scan'` → 推 `CprintScanPage()` |
| `lib/services/campus/cas_client.dart:199-228` | **最小增量**：`rawRsaEncrypt` / `login` **一律不动**，只新增一个「可指定 service 的换票入口」`stFor(session, tgt, service)`（POST `/lyuapServer/v1/tickets/<TGT>` form{service} → 返回 `ST-…`），与既有 `ssoTo` 并存：`ssoTo` = 换票 **并访问** service（建子系统会话）；`stFor` = **只换票、不消费票据**（云打印要自己抓 `doAuth` 的 302，不能让会话层把票据吃掉）。`CasSessionCenter.stFor` 内部调它 |
| `lib/services/data_wipe.dart:26-66` | 退出登录时清 TGT 缓存与 OSESSIONID 缓存（防跨账号串台）：落盘部分随 `prefs.clear()` / `secure.deleteAll()` 顺带清掉；**内存态**需显式清（写法同 `DormService.clearToken()`，`data_wipe.dart:54`） |
| `lib/pages/user_page.dart:613-649` | 退出流程挂钩点：`_logout()` 里已有 `LocalCampusService.clear()`（`user_page.dart:618`）→ 紧邻其后加 `CasSessionCenter.clear()` + `CprintSessionStore.clear()`；`DataWipe.wipeAll()`（`user_page.dart:621`）负责落盘部分 |

> `test/service_settings_render_test.dart` 会断言 `mainServices` 数量，加条目后该测试自动覆盖新条目，无需改断言。

### 5.3 关键 API 骨架

```dart
// lib/services/campus/cprint_client.dart
class CprintClient {
  static const String host = 'zzwy.cwxu.edu.cn';
  static const int port = 9130;
  static const String base = 'http://zzwy.cwxu.edu.cn:9130';
  static const String api = '$base/api/client';

  /// 校外可访问的内网域名（显式白名单，不靠 IP 猜测）
  static const Set<String> vpnHosts = {'zzwy.cwxu.edu.cn', 'kjyy.cwxu.edu.cn'};

  CampusSession _session;            // 独立实例，不与教务会话混用
  String? _osessionId;               // OSESSIONID

  /// 换出云打印会话（OSESSIONID）。
  ///
  /// TGT 由 `CasSessionCenter` 统一持有（跨工具共享、owner=学号校验），
  /// 本类不碰密码、不做验证码登录。
  /// 返回 null 表示成功，否则是给界面看的失败原因。
  static Future<String?> ensureSession(
    CampusSession session, {
    required String username,
    required String service,   // authcenter 的 CAS service（每次随机，需现取）
  });

  Future<List<CprintScanItem>> fetchScans();
  Future<File> download(CprintScanItem item);   // 流式落盘，.part + rename
  Future<void> remove(CprintScanItem item);
}
```

```dart
// lib/services/campus/cas_session_center.dart —— 统一认证会话中心（L1）
class CasSessionCenter {
  CasSessionCenter._();

  /// 取一张指定 service 的 ST（只换票，不访问 service）。
  /// 返回 null = TGT 缺失或已失效（调用方转 ensureTgt 兜底）。
  static Future<String?> stFor(CampusSession session, String service);

  /// 确保有可用 TGT：缓存命中直接返回；否则用本机密码兜底登录一次并写缓存。
  /// password 为空串（记住密码=关）时，由调用方先弹一次输入框。
  static Future<String?> ensureTgt(
    CampusSession session, {
    required String username,
    required String password,
  });

  /// 清空内存 + 落盘的 TGT 缓存（退出登录 / 换账号时调用）。
  static Future<void> clear();
}
```

```dart
// lib/services/campus/cprint_session_store.dart —— 云打印会话缓存（L3）
class CprintSessionStore {
  CprintSessionStore._();

  /// 取 OSESSIONID：owner 必须等于当前学号且未过期，否则视为未命中。
  static Future<String?> load(String username);

  /// 落盘 OSESSIONID（owner + TTL 30~60min）。
  static Future<void> save(String username, String osessionId);

  static Future<void> clear();
}
```

**下载与分享约束**

- 落盘目录：`getApplicationDocumentsDirectory()/cprint_scan/`（App 私有目录；**AndroidManifest 无任何存储权限，不写公共 Download**）。
- 打开/分享：全仓唯一出口是 `share_plus` → `Share.shareXFiles([XFile(path)], text: name)`；**无 `open_filex` 插件**。
- PDF 预览复用 `ResourceViewerPage(title:, filePath:)`；图片用 `image` 包解码。
- 可取消下载复用 `lib/services/cancel_token.dart`。

### 5.4 分层与依赖方向

```
pages/tools/cprint_scan_page.dart
        ↓ （只允许 pages → services/campus/ 的 6 处导入方向之一）
services/campus/cprint_client.dart ──→ services/campus/campus_session.dart
        │                              services/campus/cas_client.dart
        │                              services/campus/webvpn.dart
        │──→ services/campus/cas_session_center.dart   （L1：TGT 缓存 + 换票）
        │──→ services/campus/cprint_session_store.dart  （L3：OSESSIONID 缓存）
        ↓
services/cprint_scan_storage.dart   （纯本地缓存）
```

遵守 `docs/ARCHITECTURE.md` 七条约定：缓存守卫 `if (items.isEmpty) return;`、登录闸门只用 `AuthGate`、门面包 `{'data': …}`、报错直出 `$emsg`、`primaryColor` 是 getter 不能 const。

---

## 6. UI 设计稿说明

设计稿严格对齐 App 现有视觉：主色 **#1F2937**（`AppTheme.primaryColor` 默认墨黑）、圆角 12/14/20、卡片 1px `#E5E7EB` 边框 + 轻阴影、间距 4/8/12/16/20/24、字号 11/12/13/14/16/20/24/31、语义色 success #10B981 / warning #F59E0B / danger #EF4444 / info #3B82F6。

| 图 | 内容 |
|---|---|
| `cprint_scan_01_list.png` | 扫描件列表页：01-A 多选模式（顶部「已选 N 项 / 取消 / 全选」、底部「已选 N 项 / 删除 / 下载」）+ 01-B 默认列表（网络状态条 → 全部/PDF/图片/文档/已过期 chips → 类型图标 + 文件名 + 日期 + 大小 + 过期徽标 → 保留期提示） |
| `cprint_scan_02_detail.png` | 详情预览页：上半屏纸张预览（页码器 1/6 + 页点），下半屏元信息逐行浅灰等宽标注真实字段（`szDisplayName` / `x_doctype.type`·`x_doctype.classtype` / `dwFileSize=2516582 B` · B/KB/MB 三级换算 / `dwSubmitDate`+`dwSubmitTime` · `YYYY-MM-DD HH:mm` / `dwStatus & 256 != 0` → 已过期 / 作业号 `dwJobId`）；底部「保存到手机 / 分享 / 删除」+ 右侧「字段映射与接口契约」说明面板 |
| `cprint_scan_03_states.png` | 状态全集 **10 帧**：03-A 骨架屏 / 03-B 空态 EmptyState / 03-C 登录会话已过期 / 03-D 网络不可达 / 03-E WebVPN 未登录 / 03-F 服务端未登录（code 4 无效会话）/ 03-G 下载中（进度圈 + 「下载中 2/5」）/ 03-H 下载失败（该项保留在列表可重试）/ 03-I WebVPN 深澜网关未授权（去授权）/ 03-J 已过期项置灰 + 琥珀徽标 + 禁用下载 |
| `cprint_scan_04_auth.png` | **统一认证 → 云打印会话：TGT 复用链路** 6 步流程图（① 检测网络模式 direct/webvpn/offline → ② 查本机 TGT 缓存（owner=当前学号，TTL≈2h；命中 → 直接进第 3 步换 ST，**全程无密码、无验证码、静默完成**；未命中 → 用本机 secure storage 已存密码做一次 CAS 登录 → 得 TGT → 写缓存；无保存密码 → 仅此时弹一次账号密码框）→ ③ TGT→ST 换票（`POST wxcas/lyuapServer/v1/tickets/<TGT>`，service=`kjyy.cwxu.edu.cn/authcenter/doAuth/<32hex>`）→ ④ authcenter 校验 ST 并 302 回跳 `SSOLogin?targetPageUrl=…&uniToken=…` → ⑤ 换取云打印会话 cookie（`SSOLogin` → 302 → `UniEntry?SessionId=…&Func=BackUrl_…` → 302 回目标页 → `Set-Cookie: OSESSIONID`）→ ⑥ 之后所有 `Scan/Get·Download·Del` 携带 OSESSIONID）；右侧面板 =「账密复用」说明块 + 三会话分层（CAS TGT 身份 / ST 单次 service / OSESSIONID 站点会话）+ 会话与接口清单 + 两条网络出口；下部三态：04-A 静默授权中（三段式进度，无输入框）/ 04-B 会话失效自动重连（绿条「本机已保存账号密码，直接重连（不需输入）」+ 主按钮 + 虚线说明「仅当本机未保存密码时，才会弹出一次账号密码输入框」）/ 04-C 授权成功回跳 |
| `cprint_scan_00_all.png` | 上述四张合并总览 |

> ⚠️ **文案占位说明**：设计稿里「保留 30 天后自动清理」是**示意文案，不是实测结论**。站点真实规则由服务端 `dwStatus` 位 256 决定（已过期项置灰禁下载），保留天数未从接口中暴露（`Scan/Get` 无该字段）。落地时该文案应改为「过期文件不可下载」或按图书馆口径配置，**不要把 30 天写死进代码**。

> 📌 **流程图与链路的对应说明（2026-11-25 已更新）**：`cprint_scan_04_auth.png` 已按实测链路重绘，第 2 步是「查本机 TGT 缓存」（命中即静默换票，全程不弹输入框、不出现图形验证码），第 4/5 步精确到 `doAuth/<id>?ticket=ST-…` → `SSOLogin?uniToken=…` → `UniEntry?SessionId=…&Func=BackUrl_…` → `Set-Cookie: OSESSIONID`。
> 即 **sessionId 不是直接回跳带回来的，而是 `SSOLogin` 这一跳用 `uniToken` 换出来的**，再由 `UniEntry` 落地成 `OSESSIONID`。实现细节以 §2.1、§2.4 与 §4 为准。

---

## 7. 交互逻辑

### 7.1 列表页状态机

```
                ┌──────────────┐
  进入页面 ───▶ │  boot        │
                └──────┬───────┘
       ┌───────────────┼────────────────┐
       ▼               ▼                ▼
  ①网络判定        ②会话判定         ③拉列表
  NetMode.current  Auth/Check        Scan/Get
  direct/webvpn    code==0?          code==0
  /offline              │                 │
       │            ┌────┴────┐       ┌────┴────┐
       ▼            ▼         ▼       ▼         ▼
   offline      会话有效   code==4   有数据    空数组
   「当前网络   → 直接拉    →拉起    →列表     →空态
    不可用」     列表       授权面板   +本地缓存   「暂无扫描件」
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
              授权成功→重新拉列表   失败→错误态+「改用网页版」
```

- **重入保护**：`exam_query_page.dart:166` 同款——加载中重复触发直接 return。
- **失败保缓存**：拉取失败时保留上次列表（`exam_query_page.dart:196-199`），顶部提示条说明「数据可能不是最新」。
- **下拉刷新**：`RefreshIndicator` + `AlwaysScrollableScrollPhysics()`。
- **排序**：点击标题右侧排序按钮，按 `x_sorttime` 升降切换（与站点 `#sort_btn` 一致）。

### 7.2 列表项交互

| 元素 | 行为 |
|---|---|
| 勾选框 | 仅 `dwStatus & 256 == 0` 出现；过期项无勾选框（与站点模板一致） |
| 整卡点击 | 进详情预览页 |
| 下载按钮 | 流式下载 → 落私有目录 → 弹出「下载完成」提示 + 「打开 / 分享」 |
| 过期项 | 置灰 #9c9c9c、不可勾选、不可下载，角标「已过期」 |
| 底部批量栏 | 选中 0 项时隐藏/禁用；选中 >0 显示「已选 N 项 / 下载 / 删除」；滚动过阈值固定（站点 `#footbar` 同款） |
| 全选 | 表头全选按钮，联动底部计数（`#all-select-btn` + `#select-num` 同款） |
| 删除 | 二次确认弹窗 → 逐个 `Scan/Del` → 成功后从列表移除并重新拉取（站点同款） |

### 7.3 登录授权流程（通道 A）

```
点「重新登录 / 授权」
   │
   ├─ 离线模式 → 直接报错「当前网络不可用，请连接校园网或开启 WebVPN」
   │
   ├─ 取统一认证 TGT（CasSessionCenter.ensureTgt）
   │      ├─ ① TGT 缓存命中且 owner == 当前学号
   │      │      → **静默换票：不弹任何输入框、不做验证码**
   │      │      → 换票失败 ⇒ 丢弃该 TGT，转 ②
   │      ├─ ② 缓存未命中 / 已失效 / owner 不匹配
   │      │      ├─ 读 App 已存账号（StorageService.loadUserConfig）
   │      │      │      ├─ password 非空（记住密码=开）→ 用本机密码做一次 CAS 登录
   │      │      │      └─ password 为空串（记住密码=关）→ **仅此时弹一次账号密码框**
   │      │      ├─ CAS 登录：取 kaptcha → CaptchaSolver 识别（100×25 算式，字段区间 [[0,20],[20,45],[45,70]]）
   │      │      │      ├─ 识别失败 → 换一张，最多 3 次
   │      │      │      ├─ PASSERROR → 「账号或密码错误」→ 允许重输
   │      │      │      ├─ USERLOCK → 「账号已被锁定，解锁时间 xx:xx:xx」（CAS 返回 data 前 11 字符）
   │      │      │      └─ 同账号 8 秒节流 → 「操作过于频繁，请稍后再试」
   │      │      └─ 成功 → 写入 TGT 缓存（owner=当前学号）→ 回到 ① 的换票步骤
   │      │
   │      └─ 校外追加：WebVpn.login(session, tgt)
   │             ├─ 'VPN不可达' / 'VPN换票失败' / 'VPN未登录' / 'VPN验证失败' → 对应文案
   │
   ├─ SSoPage → authcenter → TGT 换 ST(service=doAuth/<id>) → doAuth → 拿 SSOLogin?uniToken
   │
   ├─ SSOLogin（GET，必须带 uniToken）→ UniEntry（GET，必须带 SessionId+Func）→ 拿 OSESSIONID
   │      ├─ 成功 → 写入 OSESSIONID 缓存（owner=当前学号）→ 回到列表并自动刷新
   │      └─ 302/404 异常 → 「统一认证授权失败」+ 「改用网页版打开」
   │
   └─ 任何步骤失败 → 错误态卡片（ErrorState）+「重试」+「改用网页版打开」
```

### 7.4 关键提示文案（沿用 App 风格）

| 场景 | 文案 |
|---|---|
| 需登录 | 「请登录后才能使用」（`AuthGate.loginRequiredMessage`，全 App 唯一闸门） |
| 校外未登录网关 | 「请先登录 WebVPN，或连接校园网后重试」 |
| 会话失效 | 「登录状态已失效，请重新授权」 |
| 账号锁定 | 「账号已被锁定，请于 {解锁时间} 后重试」 |
| 无扫描件 | 「暂无扫描件」+ 副文案「打印店代扫上传的文件会出现在这里」 |
| 过期 | 「该文件已过期，不可下载」 |
| 授权失败兜底 | 「统一认证授权失败，可改用网页版打开」 |

---

## 8. 风险与验收

### 8.1 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 站点 443 不通 | 校外/校内直连都会被 https 升级打死 | `httpsOnlyExclusions` 加 `'zzwy.cwxu.edu.cn'`（**已实测为硬性前置**） |
| 云打印账号库里没有该生 | 站点提示「云打印系统内没有您的账号信息」（errorCode 16777228） | 引导联系图书馆技术部；App 侧识别该 errorCode 单独提示 |
| CAS 失败锁号 | 学校按失败次数计锁 | 复用 `CasClient` 的 8 秒节流 + `maxAttempts=3`；**禁止自动重试密码** |
| 站点改版（当前 `V3.0.20220822`） | 字段/接口变更 | 数据模型集中一处（`cprint_models.dart`）；通道 B 随时可接管 |
| WebVPN 网关策略变更 | 校外不可用 | 通道 B 与通道 A 共用 `DormService.vpnCookies` 注入逻辑 |
| 校外 WebVPN 域名包装未跑通真实响应（**已解除**） | 校外通道整体不可用 | ✅ **已解除**（2026-11-25 `cprint_webvpn_chain.py` 校外全链实测跑通：网关 ticket → 域名包装 → SSO → `Auth/Check code=0` → `Scan/Get` 返回应用层 JSON）—— 见 §2.3 |
| `WebVpn.needsWrap` 只认私网 IP | App 主动请求 `zzwy.cwxu.edu.cn` 时不会被包装，会退回登录页 | 新增**显式域名白名单**（`zzwy.cwxu.edu.cn`、`kjyy.cwxu.edu.cn`）命中即包装；`webvpn.cwxu.edu.cn` 自身放行不包装 |
| 隐私 | 扫描件可能含敏感信息 | 只落 App 私有目录；不写公共 Download；不自动上传 |

### 8.2 验收清单

- [x] **校内直连：SSO 全链路跑通**（2026-11-25 用 App 真实 `CasClient` + `CampusSession` 实测：`Auth/Check` `code:0`、`szTrueName=车雷`）
- [x] **同一 TGT 连续两次完成云打印 SSO（无二次密码输入）** —— 已实测通过（`cprint_tgt_reuse.py`：第二次没有再输密码和验证码，`Auth/Check` 仍 `code=0`、`Scan/Get` 正常）
- [ ] 列表能出（当前账号 `result` 为 `null` = 空列表，需另找有扫描件的账号验证渲染）、过期项置灰不可下载、批量下载/删除可用
- [x] **校外：WebVPN 登录后同样可用**（网关 ticket + 域名包装）—— 2026-11-25 实测通过（`cprint_webvpn_chain.py`：网关下发 `wengine_vpn_ticketwebvpn_cwxu_edu_cn`，`zzwy.cwxu.edu.cn` 被包装为 `http-9130/<encHost>/…`，`Auth/Check code=0`、`Scan/Get` 返回应用层 JSON）
- [ ] 会话失效（手动清 OSESSIONID）→ 拉起授权面板 → 授权成功后自动回到列表
- [ ] 下载产物落 `getApplicationDocumentsDirectory()/cprint_scan/`，可分享、可预览 PDF
- [ ] 离线模式给出明确提示，不出现空转圈
- [ ] `flutter analyze lib test` 与 `flutter test` 全绿（含 `service_settings_render_test` 新条目）

> ⚠️ 本机 SDK 是 **Dart 3.5.3 / Flutter 3.24.3**，而项目要求 **Dart 3.7.2 / Flutter 3.29.3**（`docs/ARCHITECTURE.md:105-119`）。
> 用 3.5.3 跑 `flutter test` 会有 **68 个与本次改动无关的既有失败**（`Color.toARGB32` 是 Dart 3.7 才有的 API，失败点在 `app_theme.dart` / `storage_service.dart` / `widget_sync_service.dart` 等未触碰的文件；已用 `git stash` 验证过基线）。
> **请用项目指定的 SDK 复跑**；本机 Flutter 3.24.3 还会重写 `pubspec.lock`，跑完记得 `git checkout -- pubspec.lock`。

---

## 9. 附：实测脚本清单

### 9.1 Python 探针（`D:\workdsh\`）

| 脚本 | 用途 |
|---|---|
| `probe_auth.py` | CAS + 云打印完整链路复刻（**已修复 `parse_rsa` 的 modulus 截断 bug**——此前所有 `PASSERROR` 假警报的根因） |
| `probe_one.py` | 单次 CAS 登录探针：`python probe_one.py "<service url>"` |
| `sweep_actions.py` | Auth 控制器动作全枚举（138 路径） |
| `sweep_unilogin.py` | UniLogin payload 穷举（32+ 组合，全部失败 → 确认它是红鲱鱼） |
| `unilogin_rsa.py` | 站点 RSA 加密对照测试 |
| `cprint_login.py` | 云打印自有账号密码登录全链复刻（实测被拒） |
| `cprint_sso_chain.py` | **云打印 SSO 全链（Python 复刻）** |
| `cprint_tgt_reuse.py` | **TGT 复用验证：同一 TGT 连续两次跑完云打印 SSO 全链**（第二次不再输密码/验证码）—— §2.4 的实测依据 |
| `cprint_contract.py` | **SSOLogin / UniEntry 最小参数消融** |
| `cprint_webvpn.py` | **单接口 WebVPN 验证**：包装后的 `Scan/Get` / `Auth/Check` / `SSoPage` 均返回应用层 JSON，而不是登录页 HTML |
| `cprint_webvpn_chain.py` | **校外 WebVPN 全链**（网关 ticket → 域名包装 → SSO → `Auth/Check` → `Scan/Get`）—— §2.3 的实测依据 |
| `cprint_final.py` / `cprint_raw2.py` / `cprint_deep.py` / `cprint_charset.py` | 302 链、原始报文、uniToken 解码、charset 验证 |
| `mk_session.py` | 生成 `session_state.json`（供 Dart 探针复用会话） |
| `browser_real_login.py` / `browser_capture.py` | Playwright 真实浏览器登录 + 抓包（确认凭据可用、比对密文） |
| `header_ablation.py` / `cas_simple_flow.py` | 头部必要性消融、captcha 取法对比（结论：都不需要改 App） |
| `probe_fakeuser.py` / `probe_ojpwd.py` | 不存在学号 / OJ 口令的对照实验 |
| `dartprobe/main.dart` | Dart `HttpClient` 对 3 条 `Set-Cookie` 的暴露方式实证 |

### 9.2 Dart 探针（`C:\build_ws\xiyuan_pocket\tool\`）

| 脚本 | 用途 |
|---|---|
| `cas_env_probe.dart` | 用 App 真实 `CasClient` 验证登录（**密码必须走环境变量**，Windows shell 会吞掉 `^`） |
| `cas_debug.dart` | 打印 uid / 验证码答案 / 密文 / 原始响应体 |
| `cprint_sso_probe.dart` | **用 App 真实 `CasClient` + `CampusSession` 跑完整云打印 SSO 链（8 步）**——§1.4 的日志就来自它 |

> 运行方式（密码含 `^` 时务必用环境变量）：
>
> ```bash
> CAS_USER=25350103 CAS_PW='778899clcc.0QWE' dart run tool/cprint_sso_probe.dart
> ```

站点前端源码已落盘：`cprint_login.js`、`cprint_common.js`、`cprint_host.js`、`cprint_scanDoc.js`、`scanDoc.html`、`authcenter_index.html`。
