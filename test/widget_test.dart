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

  test('times use the Arabic 12 hour clock and branch logos map safely', () {
    expect(formatTime(DateTime(2026, 7, 12, 0, 5)), '12:05 ص');
    expect(formatTime(DateTime(2026, 7, 12, 16, 45)), '4:45 م');
    expect(branchLogoAsset('فرع حمص - طريق الشام'), 'assets/branches/homs_sham_road.png');
    expect(branchLogoAsset('فرع إدلب'), 'assets/branches/idlib.png');
    expect(branchLogoAsset('فرع جديد'), isNull);
  });

  test('report labels and flexible numeric values are parsed safely', () {
    expect(reportDayLabel('2026-07-12'), '12/07');
    expect(reportDayLabel('invalid'), 'invalid');
    expect(nullableIntValue('12'), 12);
    expect(nullableIntValue(null), isNull);
    expect(intValue('7'), 7);
    expect(doubleValue('2.5'), 2.5);
  });

  test('amounts, PDF chunks, and chat dates use compact display values', () {
    expect(formatMoneyValue(12000), '12,000');
    expect(formatMoneyValue(12000.50), '12,000.5');
    expect(chunkList([1, 2, 3, 4, 5], 2), [
      [1, 2],
      [3, 4],
      [5],
    ]);
    expect(shortPdfText('abcdef', 5), 'abcd…');
    expect(sameCalendarDay(DateTime(2026, 7, 12, 1), DateTime(2026, 7, 12, 23)), isTrue);
    expect(sameCalendarDay(DateTime(2026, 7, 11), DateTime(2026, 7, 12)), isFalse);
    expect(formatMoneyValue('12500.00'), '12,500');
    expect(hasVisiblePrice('12500'), isTrue);
    expect(
      productSearchScore(
        {'mat_num': '10', 'name': 'كتاب تجريبي'},
        normalizeSearch('كتاب'),
        ['كتاب'],
        const {},
      ),
      greaterThan(0),
    );
    expect(safeSearchPattern('كتاب_%'), 'كتاب');
    expect(
      rankProductRows(
        [
          {'mat_num': '2', 'name': 'شرح رياض الصالحين'},
          {'mat_num': '1', 'name': 'رياض الصالحين'},
        ],
        'رياض الصالحين',
        const {},
        limit: 10,
      ).first['mat_num'],
      '1',
    );
  });

  testWidgets('product detail tables render compact rows without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _testShell(
        ProductDetailsTable(
          title: 'الأسعار المعتمدة',
          icon: Icons.sell_outlined,
          headers: const ['نوع السعر', 'القيمة'],
          rows: const [
            ['السعر القائم', '12,500'],
            ['سعر المفرق', '15,000'],
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('الأسعار المعتمدة'), findsOneWidget);
    expect(find.text('12,500'), findsOneWidget);
  });

  testWidgets('chat bubble shows sender image fallback and date safely', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _testShell(
        ChatMessageBubble(
          row: {
            'body': 'رسالة تجريبية',
            'created_at': '2026-07-12T10:30:00Z',
            'reply_to_id': 'old-message',
            'reply_preview_sender': 'محمد',
            'reply_preview_body': 'الرسالة الأصلية',
            'forwarded_from_id': 'forwarded-message',
            'edited_at': '2026-07-12T10:35:00Z',
          },
          mine: false,
          senderName: 'إبراهيم عسكر',
          avatarUrl: null,
          showDate: true,
          showIdentity: true,
          onLongPress: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('إبراهيم عسكر'), findsOneWidget);
    expect(find.text('رسالة تجريبية'), findsOneWidget);
    expect(find.text('الرسالة الأصلية'), findsOneWidget);
    expect(find.text('تم التحويل'), findsOneWidget);
    expect(find.text('معدّلة'), findsOneWidget);
  });

  testWidgets('deleted chat message renders a stable tombstone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _testShell(
        ChatMessageBubble(
          row: const {
            'body': 'نص يجب ألا يظهر',
            'created_at': '2026-07-12T10:30:00Z',
            'deleted_at': '2026-07-12T10:31:00Z',
          },
          mine: true,
          senderName: 'أنت',
          avatarUrl: null,
          showDate: false,
          showIdentity: false,
          onLongPress: null,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('تم حذف هذه الرسالة'), findsOneWidget);
    expect(find.text('نص يجب ألا يظهر'), findsNothing);
  });

  testWidgets('invoice table fits a mobile screen without horizontal scrolling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _testShell(
        SingleChildScrollView(
          child: InvoiceItemsTable(
            branches: {1: BranchOption(number: 1, name: 'فرع حمص')},
            items: const [
              {
                'matnum': '10',
                'product_name': 'كتاب طويل الاسم لاختبار عرض الجدول ضمن شاشة الهاتف',
                'quantity': '2',
                'price': '12500',
                'value': '25000',
                'remarki': '__sto:1',
              },
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('بنود الفاتورة'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('new group page lists employees from different branches', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = EmployeeSession({
      'id': 'current',
      'display_name': 'المستخدم الحالي',
      'username': 'current',
      'branch_num': 1,
      'role': 'employee',
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAnsarTheme(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CreateThreadPage(
            session: session,
            branches: {
              1: BranchOption(number: 1, name: 'فرع حمص'),
              2: BranchOption(number: 2, name: 'فرع إدلب'),
            },
            employees: [
              EmployeeLite(id: 'current', name: 'المستخدم الحالي', username: 'current', branchNum: 1, role: 'employee', isActive: true),
              EmployeeLite(id: 'one', name: 'موظف حمص', username: 'homs', branchNum: 1, role: 'employee', isActive: true),
              EmployeeLite(id: 'two', name: 'موظف إدلب', username: 'idlib', branchNum: 2, role: 'employee', isActive: true),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('موظف حمص'), findsOneWidget);
    expect(find.text('موظف إدلب'), findsOneWidget);
    expect(find.textContaining('فرع حمص'), findsOneWidget);
    expect(find.textContaining('فرع إدلب'), findsOneWidget);
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
