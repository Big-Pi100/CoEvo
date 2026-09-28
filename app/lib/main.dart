import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'shared/achievement_icons.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();

  // 🔑 **debug 自检**：成就图标映射表必须覆盖 `AchievementIcons.all`。
  //
  // 为什么需要：漏映射一个图标名 → 该成就**静默显示默认奖杯图标**
  // （不报错、不崩 —— 只在实际翻到那个成就时看出来，极难发现）。
  // 覆盖性无法在 `query_verify` 里验（那套是纯 Dart，不能 import Flutter），
  // 所以放在这里：**debug 构建启动即断言**，release 下 `assert` 自动消失（零成本）。
  assert(iconsCoverAll(),
      '成就图标映射表未覆盖全部图标名（见 shared/achievement_icons.dart）');

  // ══════════════════════════════════════════════════════════════════════
  // 🔴 **仅 debug · 仅 web**：关掉浏览器原生右键菜单
  //
  // # 为什么需要
  // 划词查词的工具栏（`_LookupToolbar`）在 **Chrome 上永远不显示**，原因有两层：
  //
  //   ① `SelectableRegion` 的长按手势只认 `{touch, stylus, invertedStylus}`
  //      （SDK 的 `_kLongPressSelectionDevices`，**不含 mouse**）
  //      → 鼠标长按不会产生选择。⚠️ 这一层**只能靠 Chrome 的设备模拟模式**
  //        发触摸事件来绕过（web 引擎的映射是 `pointerType`：
  //        `'touch' => PointerDeviceKind.touch`）。
  //
  //   ② web 上 `_webContextMenuEnabled` 为真时，Flutter **明确不显示自己的 toolbar**
  //      （改用浏览器原生菜单，见 SDK 原文：
  //       「Web is using native dom elements to enable clipboard functionality...」）
  //      → **本行就是解掉这一层。**
  //
  // # 为什么限定 debug
  // 产品**只做 iOS**，web 仅作为开发预览。关掉浏览器菜单会失去「复制到剪贴板」等
  // 原生能力（Flutter 明说 web 上剪贴板依赖原生 DOM）——
  // 那是**开发期可接受的代价**，但绝不该进 release。
  //
  // # ⚠️ 打开设备模拟：**别按 Ctrl+Shift+M**
  // 那是 **Chrome 浏览器级的「切换用户」快捷键** —— DevTools 没开（或没获得焦点）时
  // 会被浏览器先吃掉，表现为「弹出账号登录」。
  // 两条不冲突的路径（任选）：
  //   ① `F12` 打开 DevTools → 点左上角的 **手机/平板图标**（Toggle device toolbar）
  //   ② `F12` → `Ctrl+Shift+P`（命令面板，不会冲突）→ 输入 `device` → 选
  //      「Show Device Toolbar」
  //
  // # 用法（验证划词查词）
  //   D:\flutter\bin\flutter.bat run -d chrome
  //   → 按上面任一方式打开设备模拟 → 切到任一手机型号
  //   → **长按**正文里的词 → 应弹出「查词」工具栏 → 点它 → 弹四要素浮层
  //   ⚠️ 不切设备模拟模式的话，鼠标长按依然无反应（第 ① 层拦着）。
  //   ℹ️ 更可靠的是 **Android 模拟器**（真触摸事件，见 `docs/review/step3-reader-plan` §十二）。
  //
  // ⚠️ 真机（iPhone / Android）**不受本行影响**：那里 `kIsWeb` 为假，
  //    且 `defaultTargetPlatform` 是 iOS/Android → Flutter 自己就会显示 toolbar。
  // ══════════════════════════════════════════════════════════════════════
  if (kDebugMode && kIsWeb) {
    await BrowserContextMenu.disableContextMenu();
  }

  runApp(
    const ProviderScope(
      child: CoEvoApp(),
    ),
  );
}
