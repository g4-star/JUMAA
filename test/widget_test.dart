import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jumaa/main.dart';

void main() {
  testWidgets('JUMAA login accepts an email or phone identifier', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: JUMAALoginPage()),
    );

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Email or phone number'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('LOGIN'), findsOneWidget);
  });
}
