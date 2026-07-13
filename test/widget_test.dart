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

  test('delete for everyone belongs to the original sender only', () {
    final sender = EmployeeSession({
      'id': 'sender',
      'display_name': 'المرسل',
      'username': 'sender',
      'role': 'employee',
    });
    final otherAdmin = EmployeeSession({
      'id': 'admin',
      'display_name': 'المدير',
      'username': 'admin',
      'role': 'admin',
    });
    final message = <String, dynamic>{'sender_id': 'sender'};

    expect(canDeleteChatMessageForEveryone(message, sender), isTrue);
    expect(canDeleteChatMessageForEveryone(message, otherAdmin), isFalse);
  });

  test('chat refresh ignores identical snapshots and detects message edits', () {
    final previous = <Map<String, dynamic>>[
      {'id': 'one', 'body': 'النص', 'edited_at': null, 'deleted_at': null},
    ];
    expect(chatMessageSnapshotsEqual(previous, List<Map<String, dynamic>>.from(previous)), isTrue);
    expect(
      chatMessageSnapshotsEqual(previous, [
        {'id': 'one', 'body': 'النص المعدل', 'edited_at': '2026-07-13T10:00:00Z', 'deleted_at': null},
      ]),
      isFalse,
    );
  });

  test('notification data accepts database maps and Firebase JSON strings', () {
    expect(notificationData({'type': 'chat_message'})['type'], 'chat_message');
    expect(notificationData('{"type":"chat_message","thread_id":"one"}')['thread_id'], 'one');
    expect(notificationData('not-json'), isEmpty);
  });

  test('direct notifications reach their target and never return to the sender', () {
    final session = EmployeeSession({
      'id': 'employee-one',
      'display_name': 'الموظف الأول',
      'username': 'one',
      'branch_num': 1,
      'role': 'employee',
    });
    expect(
      isNotificationForSession({
        'employee_id': 'employee-one',
        'data': {'type': 'attendance_reminder_check_in', 'employee_id': 'employee-one'},
      }, session),
      isTrue,
    );
    expect(
      isNotificationForSession({
        'data': {'type': 'chat_message', 'sender_id': 'employee-one'},
      }, session),
      isFalse,
    );
    expect(notificationRouteForType('transfer_received'), 'transfer');
  });

  test('attendance detects backdated actions and transfer receipt validates totals', () {
    final recorded = DateTime(2026, 7, 13, 12);
    expect(isAttendanceBackdated(recorded.subtract(const Duration(hours: 2)), recorded), isTrue);
    expect(isAttendanceBackdated(recorded.subtract(const Duration(minutes: 1)), recorded), isFalse);

    final draft = TransferReceiptDraft({
      'id': 'item-one',
      'approved_quantity': 5,
    });
    addTearDown(draft.dispose);
    expect(draft.valid, isTrue);
    draft.received.text = '4';
    draft.damaged.text = '1';
    expect(draft.valid, isTrue);
    expect(draft.hasDifference, isTrue);
    draft.damaged.text = '2';
    expect(draft.valid, isFalse);
  });

  test('chat mute windows, attachment types, and received transfers are labelled safely', () {
    expect(chatParticipantIsMuted({'is_muted': false}), isFalse);
    expect(
      chatParticipantIsMuted({
        'is_muted': true,
        'muted_until': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
      }),
      isTrue,
    );
    expect(
      chatParticipantIsMuted({
        'is_muted': true,
        'muted_until': DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
      }),
      isFalse,
    );
    expect(chatAttachmentMime('PDF'), 'application/pdf');
    expect(chatAttachmentMime('xlsx'), contains('spreadsheetml'));
    expect(statusLabel('received'), 'تم الاستلام');
    expect(transferTabLabel('received'), 'المستلمة');
    expect(transferAllowedNextStatuses('preparing'), ['in_delivery', 'cancelled']);
    expect(transferAllowedNextStatuses('in_delivery'), isEmpty);
  });

  testWidgets('chat navigation displays an unread badge without changing its size', (tester) async {
    await tester.pumpWidget(
      _testShell(
        const SizedBox(
          width: 48,
          height: 48,
          child: ChatNavigationIcon(count: 7, selected: false),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('7'), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
  });

  testWidgets('chat contact tile is ready to start a private conversation', (tester) async {
    await tester.pumpWidget(
      _testShell(
        ChatThreadTile(
          thread: const {
            'id': 'contact:employee',
            'thread_type': 'contact',
            'title': 'موظف جديد',
            'thread_avatar_name': 'موظف جديد',
          },
          onTap: () {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('موظف جديد'), findsOneWidget);
    expect(find.text('بدء محادثة خاصة'), findsOneWidget);
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

  testWidgets('group-only chat creation hides the private chat mode', (tester) async {
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
            groupOnly: true,
            session: session,
            branches: const {},
            employees: [
              EmployeeLite(id: 'one', name: 'الموظف الأول', username: 'one', branchNum: 1, role: 'employee', isActive: true),
              EmployeeLite(id: 'two', name: 'الموظف الثاني', username: 'two', branchNum: 2, role: 'employee', isActive: true),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('مجموعة جديدة'), findsOneWidget);
    expect(find.text('محادثة خاصة'), findsNothing);
    expect(find.text('اسم المجموعة'), findsOneWidget);
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
