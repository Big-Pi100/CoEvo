import 'package:flutter/material.dart';

/// K12 科目配置 — 纯配置类，颜色/图标/年级映射 fallback
///
/// 前端不再硬编码科目列表，改为从 API 获取 display_name/title/goal/author。
/// 颜色和图标仍然由本地 fallback 字典提供。
class K12SubjectConfig {
  /// 英文代码，如 'math'
  final String code;

  /// 中文显示名，如 '数学'
  final String displayName;

  /// 科目主题色
  final Color color;

  /// 科目图标
  final IconData icon;

  /// 首页学段列表（g10 / g11-12 分开，首页合并后再提交 API）
  final List<String> homeGrades;

  /// K12 页学段列表（g10-12 合并）
  final List<String> k12Grades;

  /// 是否在前端渲染；false 时数据保留但不显示按钮
  final bool visible;

  const K12SubjectConfig({
    required this.code,
    required this.displayName,
    required this.color,
    required this.icon,
    required this.homeGrades,
    required this.k12Grades,
    this.visible = true,
  });
}

// ---------------------------------------------------------------------------
// Fallback 颜色/图标字典（API 数据不包含颜色和图标时使用）
// ---------------------------------------------------------------------------

/// 按 subject 代码索引的 fallback 配置列表，仅提供颜色/图标/年级映射。
/// 显示名由 API 返回的 display_name 决定，不再硬编码。
const k12SubjectFallbacks = <String, K12SubjectConfig>{
  'math': K12SubjectConfig(
    code: 'math',
    displayName: '数学',
    color: Color(0xFFE57373),
    icon: Icons.calculate,
    homeGrades: ['g1-2', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    k12Grades: ['g1-2', 'g5-6', 'g7-9', 'g10-12'],
  ),
  'chinese': K12SubjectConfig(
    code: 'chinese',
    displayName: '语文',
    color: Color(0xFF64B5F6),
    icon: Icons.menu_book,
    homeGrades: ['g1-2', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    k12Grades: ['g1-2', 'g5-6', 'g7-9', 'g10-12'],
  ),
  'english': K12SubjectConfig(
    code: 'english',
    displayName: '英语',
    color: Color(0xFF81C784),
    icon: Icons.language,
    homeGrades: ['g1-2', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    k12Grades: ['g1-2', 'g5-6', 'g7-9', 'g10-12'],
  ),
  'physics': K12SubjectConfig(
    code: 'physics',
    displayName: '物理',
    color: Color(0xFFFFB74D),
    icon: Icons.science,
    homeGrades: ['g7-9', 'g10', 'g11-12'],
    k12Grades: ['g7-9', 'g10-12'],
  ),
  'chemistry': K12SubjectConfig(
    code: 'chemistry',
    displayName: '化学',
    color: Color(0xFFBA68C8),
    icon: Icons.biotech,
    homeGrades: ['g7-9', 'g10', 'g11-12'],
    k12Grades: ['g7-9', 'g10-12'],
  ),
  'biology': K12SubjectConfig(
    code: 'biology',
    displayName: '生物',
    color: Color(0xFF4DB6AC),
    icon: Icons.pets,
    homeGrades: ['g7-9', 'g10', 'g11-12'],
    k12Grades: ['g7-9', 'g10-12'],
  ),
  'history': K12SubjectConfig(
    code: 'history',
    displayName: '历史',
    color: Color(0xFFF06292),
    icon: Icons.auto_stories,
    homeGrades: ['g7-9', 'g10', 'g11-12'],
    k12Grades: ['g7-9', 'g10-12'],
  ),
  'geography': K12SubjectConfig(
    code: 'geography',
    displayName: '地理',
    color: Color(0xFF4FC3F7),
    icon: Icons.explore,
    homeGrades: ['g7-9', 'g10', 'g11-12'],
    k12Grades: ['g7-9', 'g10-12'],
  ),
  'politics': K12SubjectConfig(
    code: 'politics',
    displayName: '政治',
    color: Color(0xFFA1887F),
    icon: Icons.account_balance,
    homeGrades: ['g10', 'g11-12'],
    k12Grades: ['g10-12'],
  ),
  'science': K12SubjectConfig(
    code: 'science',
    displayName: '科学',
    color: Color(0xFF90A4AE),
    icon: Icons.travel_explore,
    homeGrades: ['g5-6', 'g7-9'],
    k12Grades: ['g5-6', 'g7-9'],
  ),
  'it': K12SubjectConfig(
    code: 'it',
    displayName: '信息技术',
    color: Color(0xFF7986CB),
    icon: Icons.computer,
    homeGrades: ['g1-2', 'g5-6', 'g7-9'],
    k12Grades: ['g1-2', 'g5-6', 'g7-9'],
  ),
  'japanese': K12SubjectConfig(
    code: 'japanese',
    displayName: '日语',
    color: Color(0xFFE0A050),
    icon: Icons.translate,
    homeGrades: ['g5-6', 'g7-9', 'g10', 'g11-12'],
    k12Grades: ['g5-6', 'g7-9'],
    visible: false,
  ),
  'russian': K12SubjectConfig(
    code: 'russian',
    displayName: '俄语',
    color: Color(0xFFC0392B),
    icon: Icons.translate,
    homeGrades: ['g7-9', 'g10', 'g11-12'],
    k12Grades: ['g7-9'],
    visible: false,
  ),
};

/// 学段名称映射（首页 + K12 页共用）
const k12GradeNames = <String, String>{
  'g1-2': '小学低年级',
  'g5-6': '小学高年级',
  'g7-9': '初中',
  'g10-12': '高中',
};
