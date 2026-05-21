// 管线注册表
//
// 与后端 pipeline_router.rs 对齐。
// 定义前端可用的管线及其元数据。

enum PipelineDomain {
  general('general', '通用学习'),
  math('math', '数学/物理学习'),
  language('language', '语言学习');

  final String value;
  final String displayName;
  const PipelineDomain(this.value, this.displayName);
}

/// 解析 domain 字符串到 PipelineDomain
PipelineDomain resolveDomain(String? domain) {
  switch (domain) {
    case 'math':
      return PipelineDomain.math;
    case 'vocabulary':
    case 'grammar':
    case 'language':
      return PipelineDomain.language;
    default:
      return PipelineDomain.general;
  }
}

/// 管线配置
class PipelineConfig {
  final PipelineDomain domain;
  final String displayName;
  final List<String> availableVerifications;

  const PipelineConfig({
    required this.domain,
    required this.displayName,
    required this.availableVerifications,
  });
}

/// 获取管线配置
PipelineConfig getPipelineConfig(PipelineDomain domain) {
  switch (domain) {
    case PipelineDomain.math:
      return const PipelineConfig(
        domain: PipelineDomain.math,
        displayName: '数学/物理学习',
        availableVerifications: ['ai_dialogue'],
      );
    case PipelineDomain.language:
      return const PipelineConfig(
        domain: PipelineDomain.language,
        displayName: '语言学习',
        availableVerifications: ['spelling', 'ai_dialogue'],
      );
    case PipelineDomain.general:
      return const PipelineConfig(
        domain: PipelineDomain.general,
        displayName: '通用学习',
        availableVerifications: ['ai_dialogue'],
      );
  }
}
