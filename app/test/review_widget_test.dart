import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coevo_app/screens/review_screen.dart';

void main() {
  testWidgets('ReviewScreen shows empty state when no cards', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ReviewScreen(),
        ),
      ),
    );

    // Should show review page title
    expect(find.text('复习'), findsOneWidget);
  });

  testWidgets('ReviewScreen renders with AppBar', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ReviewScreen(),
        ),
      ),
    );

    // ReviewScreen 无数据时不显示 TabBar, 但有 AppBar
    expect(find.byType(AppBar), findsOneWidget);
  });
}
