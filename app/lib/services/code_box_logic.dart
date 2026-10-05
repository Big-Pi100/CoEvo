// CoEvo · 6 格验证码输入的**纯逻辑**（零 import）
//
// # 🔴 为什么单独抽一个「零 import」的文件
//
// 本机**跑不了 `flutter`**（鸿蒙 SDK 231，见 MEMORY.md「本机跑不了 flutter」）
// ⇒ 任何 `import 'package:flutter/...'` 的文件在本机**无法验证**，
//    只能等 CI 的 `frontend` job 或白哥真机。
//
// 而「6 格」这个组件里，**最容易做错的部分恰好是纯计算**：
// 跳格、退格回退、粘贴分配、拼接顺序 —— 它们与渲染无关。
// 抽出来 ⇒ 能用**纯 Dart**（`dart run`，本机可跑）断言覆盖，
// 不必等到 CI。
//
// 📌 判据：**本机验证边界** —— 「import Flutter 的验不了 ⇒ 抽零 import 的纯函数」。
//    同族先例：`services/speech_chunks.dart`（TTS 分段）· `services/word_lookup.dart`。
//
// # 🔴 为什么这些看起来「显然」的函数也值得单独写 + 断言
//
// 「输入一位跳下一格」这种逻辑，写在 `onChanged` 里三行就完了 ——
// 但它的**边界**全是坑：
//   · 最后一格再输入 ⇒ 越界（要停在最后一格，不是跳到不存在的第 7 格）
//   · 第一格退格 ⇒ 负索引
//   · 粘贴 8 位 ⇒ 越界写入
//   · 粘贴含空格/换行的文本（从邮件里连说明一起复制）⇒ 必须清洗
// 而这些边界**在真机上很难手测到**（要恰好贴着边界操作）。
// ⇒ 写成纯函数 + 断言，边界才是被**证明**过的，而不是「大概没问题」。

/// 验证码位数 —— **6 位数字**（与后端 `auth::issue_reset_code` 生成的位数一致）。
///
/// 🔴 两侧必须同值：后端生成 6 位，前端只有接受 6 位才不会出现
///    「填满了却被拒」或「填 5 位就提交」。
/// ⚠️ 后端是**权威**（`format!("{:06}", ...)`）；若将来改位数，两处一起改。
const int kCodeBoxCount = 6;

/// 只保留数字，并截断到 [kCodeBoxCount] 位。
///
/// 🔑 **必须清洗**：粘贴的来源通常是邮件正文，用户很容易**连说明一起复制**，
///    于是剪贴板里是 `"你的验证码是 482913，10 分钟内有效"` 这样的整段文字。
///    直接按字符分配 ⇒ 格子里会塞进「你」「的」等汉字。
///
/// 🔑 **截断而不是报错**：粘 8 位数字多半是「多复制了一点」，
///    取前 6 位是用户期望的行为；报错反而要用户手动删除。
String cleanCodeInput(String raw) {
  final digits = raw.replaceAll(RegExp('[^0-9]'), '');
  return digits.length > kCodeBoxCount
      ? digits.substring(0, kCodeBoxCount)
      : digits;
}

/// 在某格输入完一位后，焦点应落到哪一格。
///
/// · 非最后一格 ⇒ 下一格
/// · **最后一格 ⇒ 停在最后一格**（不越界）
int focusAfterInput(int index) {
  if (index < 0) return 0;
  return index >= kCodeBoxCount - 1 ? kCodeBoxCount - 1 : index + 1;
}

/// 按退格键后，焦点应落到哪一格。
///
/// [currentTextEmpty] = **按下退格之前**，当前格是否已经是空的。
///
/// | 当前格 | 行为 | 为什么 |
/// |---|---|---|
/// | 非空 | 清空它，焦点**不动** | 符合直觉：删掉刚输的那位 |
/// | 空 | **回上一格**（第一格则留在原地） | 🔴 否则「连续退格」会在空格里卡住 —— 用户连按退格却什么也没删掉 |
///
/// 📌 注意：`Flutter` 里「退格到空格」**不触发 `onChanged`**
///    （内容本来就是空 ⇒ 没有变更事件）⇒ 调用方必须另配按键监听，
///    本函数只负责**算**该去哪，不负责**检测**按键。
int focusAfterBackspace(int index, {required bool currentTextEmpty}) {
  if (index <= 0) return 0;
  if (!currentTextEmpty) return index;
  return index - 1;
}

/// 把 6 格的内容拼成完整验证码（按**从左到右**的顺序）。
String joinCodeBoxes(List<String> boxes) => boxes.join();

/// 是否已填满 [kCodeBoxCount] 位。
bool isCodeComplete(String code) => code.length == kCodeBoxCount;

/// 【补】计算 6 格当前还缺哪些位（用于「未填满不给提交」的提示）。
///
/// 返回**空列表** = 已填满。
List<int> emptyBoxIndexes(List<String> boxes) {
  final out = <int>[];
  for (var i = 0; i < boxes.length && i < kCodeBoxCount; i++) {
    if (boxes[i].isEmpty) out.add(i);
  }
  return out;
}

/// 粘贴时，从第 [from] 格开始**逐格写入**的字符列表。
///
/// # 🔴 为什么必须有这个函数（而不是在 `onChanged` 里直接处理）
///
/// `TextField` 的 `onChanged` 在粘贴时**一次给出多个字符**
/// （粘贴 `"482913"` ⇒ `value == "482913"`，而 `maxLength: 1` 并不阻止它）。
/// 若代码假定「一次一个字符」，粘贴就会**只填第一格**，用户以为没生效。
///
/// 🔑 只返回**实际放得下**的字符：
///    · 从第 4 格粘 6 位 ⇒ 只能放 2 位（后面的格子不存在）
///    · 从第 0 格粘 8 位 ⇒ 前 6 位（`cleanCodeInput` 已截断）
///    调用方拿到这个列表后**按索引逐格赋值**即可，不必再自己算边界。
///
/// ⚠️ [from] 越界时返回**空列表**（而不是抛异常）——
///    调用方是 UI 回调，抛异常会变成一个用户可见的崩溃。
List<String> distributePasted(String pasted, int from) {
  if (from < 0 || from >= kCodeBoxCount) return const <String>[];
  final cleaned = cleanCodeInput(pasted);
  final room = kCodeBoxCount - from;
  final take = cleaned.length > room ? cleaned.substring(0, room) : cleaned;
  return take.split('');
}
