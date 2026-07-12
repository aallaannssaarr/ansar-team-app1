import 'package:ansar_team_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _testShell(Widget child) {
  return MaterialApp(
    theme: buildAnsarTheme(),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  test('cleanError hides Flutter setState Future noise', () {
    expect(
      cleanError('setState() callback argument returned a Future'),
      isEmpty,
    );
    expect(
      cleanError('x'.padRight(260, 'x')),
      'تعذر تنفيذ العملية الآن. حاول مرة أخرى.',
    );
  });

  test('product search ranks exact and phrase matches first', () {
    final barcodes = <int, String>{};
    final exact = {
      'mat_num': 1,
      'name': 'رياض الصالحين',
    };
    final partial = {
      'mat_num': 2,
      'name': 'شرح رياض الأطفال',
    };
    final query = normalizeSearch('رياض الصالحين');
    final words = query.split(' ');

    expect(
      productSearchScore(exact, query, words, barcodes),
      greaterThan(productSearchScore(partial, query, words, barcodes)),
    );
  });

  testWidgets('product card hides zero prices and shows negative stock', (tester) async {
    await tester.pumpWidget(
      _testShell(
        ProductResultCard(
          result: ProductResult(
            product: {
              'mat_num': 10,
              'name': 'رياض الصالحين',
              'quantity': -2,
              'jard_price': 0,
              'regular_price': 12500,
              'price1': null,
              'price2': 0,
              'price3': 15000,
            },
            stock: [
              StockResult(branchName: 'فرع حمص', quantity: -3),
              StockResult(branchName: 'فرع إدلب', quantity: 4),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('رياض الصالحين'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('سعر الجرد'), findsNothing);
    expect(find.text('السعر القائم'), findsOneWidget);
    expect(find.text('سعر المفرق'), findsOneWidget);
    expect(find.text('فرع حمص'), findsOneWidget);
    expect(find.text('-3'), findsOneWidget);
  });

  testWidgets('branch status card renders open state without overflow', (tester) async {
    await tester.pumpWidget(
      _testShell(
        BranchStatusCard(
          onTap: () {},
          branch: BranchStatus(
            branchNum: 1,
            branchName: 'فرع حمص',
            activeEmployees: [
              EmployeeLite(
                id: '1',
                name: 'مدير النظام',
                username: 'admin',
                branchNum: 1,
                role: 'admin',
                isActive: true,
              ),
              EmployeeLite(
                id: '2',
                name: 'إبراهيم عسكر',
                username: 'ibrahim',
                branchNum: 1,
                role: 'employee',
                isActive: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('فرع حمص'), findsOneWidget);
    expect(find.text('مفتوح الآن'), findsOneWidget);
    expect(find.textContaining('2 موظفين'), findsOneWidget);
  });

  test('branch attendance duration is calculated across daily sessions', () {
    final employee = EmployeeLite(
      id: '1',
      name: 'إبراهيم عسكر',
      username: 'ibrahim',
      branchNum: 1,
      role: 'employee',
      isActive: true,
    );
    final employeeDay = BranchEmployeeDay(
      employee: employee,
      entries: [
        BranchAttendanceEntry(
          id: 'first',
          employee: employee,
          checkIn: DateTime(2026, 7, 12, 8),
          checkOut: DateTime(2026, 7, 12, 10, 30),
        ),
        BranchAttendanceEntry(
          id: 'second',
          employee: employee,
          checkIn: DateTime(2026, 7, 12, 11),
          checkOut: DateTime(2026, 7, 12, 13),
        ),
      ],
    );

    final duration = employeeDay.workedUntil(
      DateTime(2026, 7, 12, 14),
      DateTime(2026, 7, 12),
    );

    expect(duration, const Duration(hours: 4, minutes: 30));
    expect(formatDurationCompact(duration), '4 س 30 د');
  });

  testWidgets('top bar fits mobile width with profile and notifications', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = EmployeeSession({
      'id': '1',
      'display_name': 'إبراهيم عسكر',
      'username': 'ibrahim1',
      'branch_num': 1,
      'role': 'employee',
    });

    await tester.pumpWidget(
      _testShell(
        AnsarTopBar(
          session: session,
          onAction: (_) {},
          onNotificationTap: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('فريق الأنصار'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
  });
}
