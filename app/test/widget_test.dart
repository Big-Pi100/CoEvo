import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coevo_app/app.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: CoEvoApp(),
      ),
    );
    // 验证 App 正常渲染（auth 页面需要 pumpAndSettle 等待路由跳转）
    await tester.pumpAndSettle();
    expect(find.byType(CoEvoApp), findsOneWidget);
  });
}
