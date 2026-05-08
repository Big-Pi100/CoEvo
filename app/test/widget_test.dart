import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coevo_app/app.dart';

void main() {
  testWidgets('App starts with auth screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: CoEvoApp(),
      ),
    );
    expect(find.text('刻意进化'), findsOneWidget);
  });
}
