# flutter_chaoxing（本地 fork）

上游：[flutter_chaoxing 0.4.2](https://pub.dev/packages/flutter_chaoxing)
（Apache-2.0，TsinbeiLabs）。本目录是未修改源码的裁剪副本，
裁剪理由与清单见 `lib/flutter_chaoxing.dart` 的文件头注释。

**升级上游时不要覆盖本目录**：先把新版本解包到别处，按同样规则删掉
`chaoxing_sign_service.dart` / `chaoxing_captcha.dart` /
`chaoxing_user_agent.dart`，再检查剩下文件里有没有 3.8+ 专有语法
（重点搜 `: ?` 形式的空感知 map 元素），最后跑
`flutter analyze lib` 与 `dart pub get` 两道。`LICENSE` 必须保留。
