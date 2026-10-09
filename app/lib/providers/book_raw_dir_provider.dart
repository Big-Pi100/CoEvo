// CoEvo · 电子书**原始文件**的目录 —— 唯一权威
//
// 🔴 为什么单独抽出来：**三个地方要用同一个目录**（导入保存 / 上传读取 / 下载写入）。
//    若各自算一遍，任一处的拼接规则漂了就会出现「导入存到 A、上传去 B 找」
//    —— 表现为「明明导入过却提示没有原始文件」，且**不报错**。
//    📌 判据：**同一件事的口径只能一处权威。**
//
// ⚠️ 本文件属于 **Flutter 层**（要 `path_provider`）——
//    纯逻辑层（`book_raw_store.dart` / `book_importer.dart`）只接受**传入的目录字符串**，
//    这样它们仍能在本机被 `dart run` 直接验证。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// 原始文件目录：`{AppSupport}/books_raw`。
///
/// 🔑 与 `book.db` / `user.db` 同在 AppSupport —— 它们同属 **App 私有数据**，
///    备份与迁移应当一起走。⚠️ 不要放 cache（会被系统清掉，
///    而清掉之后「上传」与「换机复用解析器」就都失效了）。
Future<String> rawBooksDir() async {
  final dir = await getApplicationSupportDirectory();
  return '${dir.path}${Platform.pathSeparator}books_raw';
}

/// 给 Riverpod 侧用（异步、缓存一次）。
final bookRawDirProvider = FutureProvider<String>((ref) => rawBooksDir());
