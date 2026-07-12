import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ansar_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await Supabase.initialize(
    url: AnsarConfig.supabaseUrl,
    publishableKey: AnsarConfig.supabaseServiceKey,
  );
  runApp(const AnsarApp());
}

SupabaseClient get supabase => Supabase.instance.client;
List<Map<String, dynamic>>? cachedProducts;
Map<int, String>? cachedBarcodes;
Future<List<Map<String, dynamic>>>? cachedProductsFuture;
Future<Map<int, String>>? cachedBarcodesFuture;
List<Map<String, dynamic>>? cachedAccounts;
Future<List<Map<String, dynamic>>>? cachedAccountsFuture;
String? lastNotificationTokenPreview;
String? lastNotificationRegistrationError;
DateTime? lastNotificationRegistrationAt;
StreamSubscription<String>? notificationTokenRefreshSubscription;

const brandColor = Color(0xff006a57);
const brandDark = Color(0xff004d40);
const accentColor = Color(0xffd79a2b);
const inkColor = Color(0xff192723);
const mutedInk = Color(0xff66736f);
const softSurface = Color(0xfff6f8f7);
const panelSurface = Color(0xffffffff);
const borderColor = Color(0xffdfe6e3);
const successColor = Color(0xff169b55);
const dangerColor = Color(0xffd94d49);
const infoColor = Color(0xff2d6fc1);
const warningSurface = Color(0xfffff6e5);
const successSurface = Color(0xffeaf7f0);

const pagePadding = EdgeInsets.fromLTRB(16, 12, 16, 24);

ThemeData buildAnsarTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: brandColor,
    brightness: Brightness.light,
    primary: brandColor,
    secondary: accentColor,
    surface: panelSurface,
    error: dangerColor,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: softSurface,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        color: inkColor,
        fontWeight: FontWeight.w800,
        height: 1.35,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        color: inkColor,
        fontWeight: FontWeight.w800,
        height: 1.35,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        color: inkColor,
        fontWeight: FontWeight.w700,
        height: 1.4,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(color: inkColor, height: 1.55),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(color: inkColor, height: 1.55),
      bodySmall: base.textTheme.bodySmall?.copyWith(color: mutedInk, height: 1.45),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
    ),
    appBarTheme: const AppBarThemeData(
      centerTitle: true,
      backgroundColor: panelSurface,
      foregroundColor: inkColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: inkColor,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        height: 1.35,
      ),
      iconTheme: IconThemeData(color: inkColor),
    ),
    cardTheme: const CardThemeData(
      color: panelSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: borderColor),
      ),
    ),
    dividerTheme: const DividerThemeData(color: borderColor, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: panelSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: const TextStyle(color: mutedInk),
      hintStyle: const TextStyle(color: Color(0xff8a9692)),
      prefixIconColor: mutedInk,
      suffixIconColor: mutedInk,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: brandColor, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: dangerColor),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: dangerColor, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 50),
        foregroundColor: brandColor,
        side: const BorderSide(color: borderColor),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brandColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: inkColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: brandColor,
      foregroundColor: Colors.white,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: panelSurface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: successSurface,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(color: states.contains(WidgetState.selected) ? brandColor : mutedInk, size: 24);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return TextStyle(
          color: states.contains(WidgetState.selected) ? brandColor : mutedInk,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
        );
      }),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: const Color(0xfff0f4f2),
      selectedColor: successSurface,
      side: const BorderSide(color: borderColor),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      labelStyle: const TextStyle(color: inkColor, fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: panelSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: panelSurface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: inkColor,
      contentTextStyle: const TextStyle(color: Colors.white, height: 1.4),
      behavior: SnackBarBehavior.floating,
      elevation: 2,
      insetPadding: const EdgeInsets.all(14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: brandColor),
  );
}

class AnsarApp extends StatelessWidget {
  const AnsarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'فريق الأنصار',
      theme: buildAnsarTheme(),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: LoginPage(),
      ),
    );
  }
}

class EmployeeSession {
  EmployeeSession(this.data);

  final Map<String, dynamic> data;

  String get id => data['id'] as String;
  String get name => (data['display_name'] ?? data['full_name'] ?? username) as String;
  String get fullName => (data['full_name'] ?? name) as String;
  String get username => data['username'] as String? ?? '';
  int get branchNum => (data['branch_num'] as num?)?.toInt() ?? 0;
  String get role => data['role'] as String? ?? 'employee';
  String? get avatarUrl => data['avatar_url'] as String?;
  String? get phone => data['phone'] as String?;
  String? get email => data['email'] as String?;
  String? get jobTitle => data['job_title'] as String?;
  bool get canManageEmployees => data['can_manage_employees'] == true;
  bool get canManageAllBranches => data['can_manage_all_branches'] == true;
  bool get isAdmin => role == 'admin' || canManageAllBranches;
  bool get isBranchManager => role == 'branch_manager';
}

class BranchOption {
  BranchOption({required this.number, required this.name});

  final int number;
  final String name;

  String get label => '$name - رقم $number';
}

class EmployeeLite {
  EmployeeLite({
    required this.id,
    required this.name,
    required this.username,
    required this.branchNum,
    required this.role,
    required this.isActive,
    this.avatarUrl,
  });

  final String id;
  final String name;
  final String username;
  final int branchNum;
  final String role;
  final bool isActive;
  final String? avatarUrl;

  factory EmployeeLite.fromRow(Map<String, dynamic> row) {
    return EmployeeLite(
      id: row['id'] as String,
      name: (row['display_name'] ?? row['full_name'] ?? row['username'] ?? '') as String,
      username: row['username'] as String? ?? '',
      branchNum: (row['branch_num'] as num?)?.toInt() ?? 0,
      role: row['role'] as String? ?? 'employee',
      isActive: row['is_active'] != false,
      avatarUrl: row['avatar_url'] as String?,
    );
  }

  factory EmployeeLite.fromSession(EmployeeSession session) {
    return EmployeeLite(
      id: session.id,
      name: session.name,
      username: session.username,
      branchNum: session.branchNum,
      role: session.role,
      isActive: true,
      avatarUrl: session.avatarUrl,
    );
  }
}

class Movement {
  Movement({
    required this.employee,
    required this.branchName,
    required this.time,
    required this.type,
  });

  final EmployeeLite employee;
  final String branchName;
  final DateTime time;
  final String type;
}

class EmployeeDuration {
  EmployeeDuration({
    required this.employee,
    required this.hours,
    required this.days,
    required this.openLogs,
  });

  final EmployeeLite employee;
  final double hours;
  final int days;
  final int openLogs;
}

class DashboardData {
  DashboardData({
    required this.movements,
    required this.branchStatuses,
    required this.activeNow,
    required this.checkedInToday,
    required this.openLog,
    required this.branchName,
  });

  final List<Movement> movements;
  final List<BranchStatus> branchStatuses;
  final int activeNow;
  final int checkedInToday;
  final Map<String, dynamic>? openLog;
  final String branchName;
}

class BranchStatus {
  BranchStatus({
    required this.branchNum,
    required this.branchName,
    required this.activeEmployees,
  });

  final int branchNum;
  final String branchName;
  final List<EmployeeLite> activeEmployees;

  bool get isOpen => activeEmployees.isNotEmpty;
}

class BranchAttendanceEntry {
  BranchAttendanceEntry({
    required this.id,
    required this.employee,
    required this.checkIn,
    required this.checkOut,
  });

  final String id;
  final EmployeeLite employee;
  final DateTime checkIn;
  final DateTime? checkOut;

  bool get isOpen => checkOut == null;

  Duration workedUntil(DateTime now, DateTime dayStart) {
    final effectiveStart = checkIn.isBefore(dayStart) ? dayStart : checkIn;
    final effectiveEnd = checkOut ?? now;
    if (effectiveEnd.isBefore(effectiveStart)) return Duration.zero;
    return effectiveEnd.difference(effectiveStart);
  }
}

class BranchEmployeeDay {
  BranchEmployeeDay({required this.employee, required this.entries});

  final EmployeeLite employee;
  final List<BranchAttendanceEntry> entries;

  bool get isPresent => entries.any((entry) => entry.isOpen);

  DateTime get firstCheckIn {
    return entries.map((entry) => entry.checkIn).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  DateTime? get lastCheckOut {
    final values = entries.map((entry) => entry.checkOut).whereType<DateTime>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Duration workedUntil(DateTime now, DateTime dayStart) {
    return entries.fold(
      Duration.zero,
      (total, entry) => total + entry.workedUntil(now, dayStart),
    );
  }
}

class BranchTodayData {
  BranchTodayData({required this.entries, required this.employeeDays});

  final List<BranchAttendanceEntry> entries;
  final List<BranchEmployeeDay> employeeDays;

  int get activeCount => employeeDays.where((employee) => employee.isPresent).length;
  int get employeeCount => employeeDays.length;

  Duration totalWorkedUntil(DateTime now, DateTime dayStart) {
    return employeeDays.fold(
      Duration.zero,
      (total, employee) => total + employee.workedUntil(now, dayStart),
    );
  }
}

class ReportData {
  ReportData({
    required this.branches,
    required this.employees,
    required this.availableEmployees,
    required this.durations,
    required this.dailyHours,
    required this.totalHours,
    required this.openLogs,
    required this.closedLogs,
  });

  final Map<int, BranchOption> branches;
  final List<EmployeeLite> employees;
  final List<EmployeeLite> availableEmployees;
  final List<EmployeeDuration> durations;
  final Map<String, double> dailyHours;
  final double totalHours;
  final int openLogs;
  final int closedLogs;

  double get averageHours {
    final sessions = closedLogs + openLogs;
    return sessions == 0 ? 0 : totalHours / sessions;
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final usernameController = TextEditingController(text: 'admin');
  bool loading = false;
  String? error;

  Future<void> login() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final username = usernameController.text.trim();
      final rows = await supabase
          .from('ansar_employees')
          .select()
          .eq('username', username)
          .eq('is_active', true)
          .limit(1);

      if (rows.isEmpty) {
        throw Exception('لم يتم العثور على موظف فعال بهذا الاسم');
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: HomePage(initialSession: EmployeeSession(rows.first)),
          ),
        ),
      );
    } catch (e) {
      setState(() => error = cleanError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: panelSurface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 132,
                        height: 132,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: softSurface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: borderColor),
                        ),
                        child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'فريق الأنصار',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 30),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'مساحة العمل اليومية لفروع مكتبة الأنصار',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: mutedInk, fontSize: 15),
                      ),
                      const SizedBox(height: 34),
                      TextField(
                        controller: usernameController,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          labelText: 'اسم المستخدم',
                          hintText: 'أدخل اسم المستخدم الخاص بك',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                        onSubmitted: (_) => login(),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: dangerColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.error_outline_rounded, color: dangerColor, size: 20),
                              const SizedBox(width: 8),
                              Expanded(child: Text(error!, style: const TextStyle(color: dangerColor))),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: loading ? null : login,
                        icon: loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.login_rounded),
                        label: Text(loading ? 'جاري الدخول' : 'دخول إلى التطبيق'),
                      ),
                      const SizedBox(height: 18),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline_rounded, size: 16, color: mutedInk),
                          SizedBox(width: 6),
                          Text('نظام داخلي مخصص لفريق العمل', style: TextStyle(color: mutedInk, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.initialSession});

  final EmployeeSession initialSession;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late EmployeeSession session;
  int index = 0;
  StreamSubscription<RemoteMessage>? foregroundMessages;
  Timer? notificationRegistrationTimer;
  Timer? inAppNotificationsTimer;
  final seenInAppNotificationIds = <String>{};
  DateTime inAppNotificationCursor = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session = widget.initialSession;
    startNotificationRegistrationMonitor();
    startInAppNotificationMonitor();
    foregroundMessages = FirebaseMessaging.onMessage.listen((message) {
      if (!mounted) return;
      if (message.data['sender_id'] == session.id || message.data['employee_id'] == session.id) return;
      final title = message.notification?.title ?? 'إشعار جديد';
      final body = message.notification?.body ?? '';
      showSnack(context, body.isEmpty ? title : '$title\n$body');
    });
  }

  void updateSession(EmployeeSession value) {
    setState(() => session = value);
    startNotificationRegistrationMonitor();
    startInAppNotificationMonitor();
  }

  void startNotificationRegistrationMonitor() {
    notificationRegistrationTimer?.cancel();
    unawaited(registerDeviceForNotifications(session));
    notificationRegistrationTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      registerDeviceForNotifications(session);
    });
  }

  void startInAppNotificationMonitor() {
    inAppNotificationsTimer?.cancel();
    inAppNotificationCursor = DateTime.now().toUtc().subtract(const Duration(seconds: 8));
    seenInAppNotificationIds.clear();
    unawaited(checkInAppNotifications());
    inAppNotificationsTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      checkInAppNotifications();
    });
  }

  Future<void> checkInAppNotifications() async {
    try {
      final rows = await supabase
          .from('ansar_notification_queue')
          .select('id, employee_id, branch_num, title, body, data, created_at')
          .gt('created_at', inAppNotificationCursor.toIso8601String())
          .order('created_at', ascending: true)
          .limit(20);
      for (final row in rows.cast<Map<String, dynamic>>()) {
        final createdAt = DateTime.tryParse(row['created_at'] as String? ?? '')?.toUtc();
        if (createdAt != null && createdAt.isAfter(inAppNotificationCursor)) {
          inAppNotificationCursor = createdAt;
        }
        if (!isNotificationForSession(row, session)) continue;
        final id = row['id'] as String? ?? '';
        if (id.isEmpty || seenInAppNotificationIds.contains(id)) continue;
        seenInAppNotificationIds.add(id);
        if (!mounted) return;
        final title = row['title'] as String? ?? 'إشعار جديد';
        final body = row['body'] as String? ?? '';
        showSnack(context, body.isEmpty ? title : '$title\n$body');
      }
    } catch (_) {
      // In-app alerts are a fallback path; they should not interrupt normal use.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    foregroundMessages?.cancel();
    notificationRegistrationTimer?.cancel();
    inAppNotificationsTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      startNotificationRegistrationMonitor();
      startInAppNotificationMonitor();
    }
  }

  Future<void> openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(title: const Text('حسابي')),
            body: ProfilePage(session: session, onSessionChanged: updateSession),
          ),
        ),
      ),
    );
  }

  Future<void> openManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(title: const Text('إدارة النظام')),
            body: ManagementPage(session: session),
          ),
        ),
      ),
    );
  }

  Future<void> openNotifications() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(title: const Text('الإشعارات')),
            body: NotificationInboxPage(session: session),
          ),
        ),
      ),
    );
  }

  void logout() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => const Directionality(
          textDirection: TextDirection.rtl,
          child: LoginPage(),
        ),
      ),
    );
  }

  Future<void> handleHeaderAction(String value) async {
    if (value == 'profile') {
      await openProfile();
      return;
    }
    if (value == 'management') {
      await openManagement();
      return;
    }
    if (value == 'logout') logout();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(key: const PageStorageKey('dashboard'), session: session),
      ReportsPage(key: const PageStorageKey('reports'), session: session),
      TransfersPage(key: const PageStorageKey('transfers'), session: session),
      QueriesPage(key: const PageStorageKey('queries'), session: session),
      ChatPage(key: const PageStorageKey('chat'), session: session),
    ];

    final destinations = [
      const NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home_rounded),
        label: 'الرئيسية',
      ),
      const NavigationDestination(
        icon: Icon(Icons.insert_chart_outlined_rounded),
        selectedIcon: Icon(Icons.insert_chart_rounded),
        label: 'التقارير',
      ),
      const NavigationDestination(
        icon: Icon(Icons.swap_horiz_rounded),
        selectedIcon: Icon(Icons.sync_alt_rounded),
        label: 'المناقلات',
      ),
      const NavigationDestination(
        icon: Icon(Icons.search_rounded),
        selectedIcon: Icon(Icons.manage_search_rounded),
        label: 'استعلام',
      ),
      const NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline_rounded),
        selectedIcon: Icon(Icons.chat_rounded),
        label: 'الدردشة',
      ),
    ];

    if (index >= pages.length) index = 0;

    return Scaffold(
      body: Column(
        children: [
          AnsarTopBar(
            session: session,
            onNotificationTap: openNotifications,
            onAction: handleHeaderAction,
          ),
          Expanded(
            child: IndexedStack(
              index: index,
              children: pages,
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: destinations,
      ),
    );
  }
}

class AnsarTopBar extends StatelessWidget {
  const AnsarTopBar({
    super.key,
    required this.session,
    required this.onAction,
    this.onNotificationTap,
  });

  final EmployeeSession session;
  final ValueChanged<String> onAction;
  final VoidCallback? onNotificationTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: panelSurface,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: borderColor)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.center,
                child: Text(
                  'فريق الأنصار',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Image.asset('assets/logo.png', width: 52, height: 52, fit: BoxFit.contain),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'قائمة الحساب',
                      position: PopupMenuPosition.under,
                      onSelected: onAction,
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'profile',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.person_outline_rounded),
                            title: Text('حسابي'),
                          ),
                        ),
                        if (session.canManageEmployees)
                          const PopupMenuItem(
                            value: 'management',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.admin_panel_settings_outlined),
                              title: Text('إدارة النظام'),
                            ),
                          ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'logout',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.logout_rounded, color: dangerColor),
                            title: Text('تسجيل الخروج', style: TextStyle(color: dangerColor)),
                          ),
                        ),
                      ],
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          EmployeeAvatar(name: session.name, imageUrl: session.avatarUrl, radius: 22),
                          Positioned(
                            left: -1,
                            bottom: -1,
                            child: Container(
                              width: 13,
                              height: 13,
                              decoration: BoxDecoration(
                                color: successColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: panelSurface, width: 2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    IconButton(
                      tooltip: 'الإشعارات',
                      onPressed: onNotificationTap,
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.notifications_none_rounded),
                          Positioned(
                            left: 1,
                            top: 1,
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(color: accentColor, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NotificationInboxPage extends StatefulWidget {
  const NotificationInboxPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<NotificationInboxPage> createState() => _NotificationInboxPageState();
}

class _NotificationInboxPageState extends State<NotificationInboxPage> {
  late Future<List<Map<String, dynamic>>> future;

  @override
  void initState() {
    super.initState();
    future = loadNotifications();
  }

  Future<List<Map<String, dynamic>>> loadNotifications() async {
    final rows = await supabase
        .from('ansar_notification_queue')
        .select('id, employee_id, branch_num, title, body, data, status, created_at')
        .order('created_at', ascending: false)
        .limit(100);
    return rows
        .cast<Map<String, dynamic>>()
        .where((row) => isNotificationForSession(row, widget.session))
        .take(50)
        .toList();
  }

  void reload() {
    setState(() => future = loadNotifications());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: reload);
        final rows = snapshot.data!;
        return RefreshIndicator(
          onRefresh: () async {
            reload();
            await future;
          },
          child: ListView(
            padding: pagePadding,
            children: [
              PageHeading(
                title: 'آخر الإشعارات',
                subtitle: 'تحديثات الدوام والمناقلات والدردشة',
                icon: Icons.notifications_none_rounded,
                action: IconButton.outlined(
                  tooltip: 'تحديث',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
              if (rows.isEmpty)
                const EmptyState(icon: Icons.notifications_off_outlined, text: 'لا توجد إشعارات جديدة')
              else
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        NotificationInboxTile(row: rows[i]),
                        if (i != rows.length - 1) const Divider(indent: 68),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class NotificationInboxTile extends StatelessWidget {
  const NotificationInboxTile({super.key, required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal();
    final data = row['data'] is Map ? Map<String, dynamic>.from(row['data'] as Map) : <String, dynamic>{};
    final type = data['type'] as String? ?? '';
    final isChat = type.contains('chat');
    final isTransfer = type.contains('transfer');
    final color = isChat
        ? infoColor
        : isTransfer
            ? accentColor
            : brandColor;
    final icon = isChat
        ? Icons.chat_bubble_outline_rounded
        : isTransfer
            ? Icons.swap_horiz_rounded
            : Icons.schedule_rounded;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 21),
      ),
      title: Text(row['title'] as String? ?? 'إشعار جديد', style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(row['body'] as String? ?? '', style: const TextStyle(color: mutedInk)),
      ),
      trailing: created == null
          ? null
          : Text(formatTime(created), style: const TextStyle(color: mutedInk, fontSize: 11)),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<DashboardData> future;
  DashboardData? latestDashboard;
  Timer? timer;
  RealtimeChannel? attendanceChannel;
  bool attendanceBusy = false;
  bool movementsExpanded = false;

  @override
  void initState() {
    super.initState();
    future = loadAndRememberDashboard();
    attendanceChannel = supabase.channel('dashboard-attendance')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_attendance_logs',
        callback: (_) {
          if (mounted) {
            setState(() {
              future = loadAndRememberDashboard();
            });
          }
        },
      ).subscribe();
    timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        setState(() {
          future = loadAndRememberDashboard();
        });
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    if (attendanceChannel != null) supabase.removeChannel(attendanceChannel!);
    super.dispose();
  }

  Future<DashboardData> loadAndRememberDashboard() async {
    final loaded = await loadDashboard();
    latestDashboard = loaded;
    return loaded;
  }

  Future<DashboardData> loadDashboard() async {
    final branches = await loadAppBranchesMap();
    final employeeRows = await supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url')
        .eq('is_active', true);
    final employees = employeeRows.cast<Map<String, dynamic>>().map(EmployeeLite.fromRow).toList();
    final employeeById = {for (final employee in employees) employee.id: employee};
    final employeeIds = employeeById.keys.toSet();
    Map<String, dynamic>? myOpenLog;

    final rows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .order('check_in_at', ascending: false)
        .limit(80);
    final openRows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .eq('status', 'open')
        .order('check_in_at', ascending: false);

    final now = DateTime.now();
    final todayKey = formatDateKey(now);
    final movements = <Movement>[];
    final activeEmployees = <String>{};
    final checkedInToday = <String>{};
    final activeByBranch = <int, Set<String>>{};

    for (final row in openRows.cast<Map<String, dynamic>>()) {
      final employeeId = row['employee_id'] as String?;
      if (employeeId == null || !employeeIds.contains(employeeId)) continue;
      final employee = employeeById[employeeId]!;
      final branchNum = (row['branch_num'] as num?)?.toInt() ?? employee.branchNum;
      activeEmployees.add(employeeId);
      activeByBranch.putIfAbsent(branchNum, () => <String>{}).add(employeeId);
      if (employeeId == widget.session.id) {
        myOpenLog ??= row;
      }
    }

    for (final row in rows) {
      final employeeId = row['employee_id'] as String?;
      if (employeeId == null || !employeeIds.contains(employeeId)) continue;
      final employee = employeeById[employeeId]!;
      final branchNum = (row['branch_num'] as num?)?.toInt() ?? employee.branchNum;
      final branchName = branchLabel(branches, branchNum);
      final checkInValue = row['check_in_at'] as String?;
      final checkOutValue = row['check_out_at'] as String?;

      if (checkInValue != null) {
        final checkIn = DateTime.parse(checkInValue).toLocal();
        if (formatDateKey(checkIn) == todayKey) checkedInToday.add(employeeId);
        movements.add(Movement(
          employee: employee,
          branchName: branchName,
          time: checkIn,
          type: 'دخول',
        ));
      }
      if (checkOutValue != null) {
        movements.add(Movement(
          employee: employee,
          branchName: branchName,
          time: DateTime.parse(checkOutValue).toLocal(),
          type: 'خروج',
        ));
      }
    }

    movements.sort((a, b) => b.time.compareTo(a.time));
    final branchStatuses = branches.values.map((branch) {
      final activeIds = activeByBranch[branch.number] ?? <String>{};
      final active = activeIds.map((id) => employeeById[id]).whereType<EmployeeLite>().toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      return BranchStatus(
        branchNum: branch.number,
        branchName: branch.name,
        activeEmployees: active,
      );
    }).toList()
      ..sort((a, b) {
        if (a.isOpen != b.isOpen) return a.isOpen ? -1 : 1;
        return a.branchName.compareTo(b.branchName);
      });
    return DashboardData(
      movements: movements.take(30).toList(),
      branchStatuses: branchStatuses,
      activeNow: activeEmployees.length,
      checkedInToday: checkedInToday.length,
      openLog: myOpenLog,
      branchName: branchLabel(branches, widget.session.branchNum),
    );
  }

  Future<void> checkIn() async {
    setState(() => attendanceBusy = true);
    try {
      await supabase.from('ansar_attendance_logs').insert({
        'employee_id': widget.session.id,
        'branch_num': widget.session.branchNum,
        'check_in_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'open',
      });
      unawaited(enqueueNotification(
        title: 'تسجيل دخول دوام',
        body: '${widget.session.name} سجل الدخول إلى الدوام',
        data: {
          'type': 'attendance_check_in',
          'employee_id': widget.session.id,
          'branch_num': widget.session.branchNum,
        },
      ));
      if (mounted) {
        setState(() {
          future = loadAndRememberDashboard();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => attendanceBusy = false);
    }
  }

  Future<void> checkOut(Map<String, dynamic> openLog) async {
    setState(() => attendanceBusy = true);
    try {
      await supabase.from('ansar_attendance_logs').update({
        'check_out_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'closed',
      }).eq('id', openLog['id']);
      unawaited(enqueueNotification(
        title: 'تسجيل خروج دوام',
        body: '${widget.session.name} سجل الخروج من الدوام',
        data: {
          'type': 'attendance_check_out',
          'employee_id': widget.session.id,
          'branch_num': widget.session.branchNum,
        },
      ));
      if (mounted) {
        setState(() {
          future = loadAndRememberDashboard();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => attendanceBusy = false);
    }
  }

  Future<void> openBranchDetails(BranchStatus branch) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: BranchTodayPage(branch: branch),
        ),
      ),
    );
    if (mounted) {
      setState(() {
        future = loadAndRememberDashboard();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DashboardData>(
        future: future,
        initialData: latestDashboard,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return ErrorState(
              message: cleanError(snapshot.error),
              onRetry: () => setState(() {
                future = loadAndRememberDashboard();
              }),
            );
          }

          final data = snapshot.data!;
          final isWorking = data.openLog != null;
          final attendanceTitle = isWorking
              ? 'دوامك مستمر منذ ${attendanceDurationLabel(data.openLog!['check_in_at'] as String?)}'
              : 'أنت خارج العمل الآن';
          return ListView(
            key: const PageStorageKey('dashboard-list'),
            padding: pagePadding,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          EmployeeAvatar(
                            name: widget.session.name,
                            imageUrl: widget.session.avatarUrl,
                            radius: 29,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  attendanceTitle,
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18),
                                ),
                                const SizedBox(height: 7),
                                Row(
                                  children: [
                                    const Icon(Icons.location_on_outlined, size: 18, color: mutedInk),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        'الفرع: ${data.branchName}',
                                        style: const TextStyle(color: mutedInk),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: isWorking ? successColor : dangerColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: panelSurface, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: (isWorking ? successColor : dangerColor).withValues(alpha: 0.18),
                                  blurRadius: 0,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const Divider(),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: isWorking ? dangerColor : brandColor,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: (isWorking ? dangerColor : brandColor).withValues(alpha: 0.55),
                          disabledForegroundColor: Colors.white,
                        ),
                        onPressed: attendanceBusy
                            ? null
                            : isWorking
                                ? () => checkOut(data.openLog!)
                                : checkIn,
                        icon: attendanceBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(isWorking ? Icons.logout_rounded : Icons.login_rounded),
                        label: Text(
                          attendanceBusy
                              ? 'جاري تنفيذ العملية'
                              : isWorking
                                  ? 'تسجيل خروج'
                                  : 'تسجيل دخول',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              DashboardViewSwitch(
                showMovements: movementsExpanded,
                onChanged: (value) => setState(() => movementsExpanded = value),
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: movementsExpanded
                    ? Card(
                        key: const ValueKey('movements'),
                        child: data.movements.isEmpty
                            ? const EmptyState(icon: Icons.event_busy_rounded, text: 'لا توجد حركات دوام بعد')
                            : Column(
                                children: [
                                  for (var i = 0; i < data.movements.length; i++) ...[
                                    MovementTile(movement: data.movements[i]),
                                    if (i != data.movements.length - 1) const Divider(indent: 62),
                                  ],
                                ],
                              ),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('branches'),
                        child: data.branchStatuses.isEmpty
                            ? const Card(
                                child: EmptyState(icon: Icons.storefront_rounded, text: 'لا توجد فروع مسجلة'),
                              )
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  final columns = constraints.maxWidth < 270 ? 1 : 2;
                                  return GridView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: data.branchStatuses.length,
                                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10,
                                      childAspectRatio: columns == 1 ? 2.2 : 1.05,
                                    ),
                                    itemBuilder: (context, index) {
                                      final branch = data.branchStatuses[index];
                                      return BranchStatusCard(
                                        branch: branch,
                                        onTap: () => openBranchDetails(branch),
                                      );
                                    },
                                  );
                                },
                              ),
                      ),
              ),
              const SizedBox(height: 12),
              Card(
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(
                        child: DashboardSummary(
                          title: 'سجلوا اليوم',
                          value: '${data.checkedInToday}',
                          icon: Icons.group_outlined,
                          color: accentColor,
                        ),
                      ),
                      const VerticalDivider(),
                      Expanded(
                        child: DashboardSummary(
                          title: 'داخل العمل الآن',
                          value: '${data.activeNow}',
                          icon: Icons.person_outline_rounded,
                          color: brandColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
    );
  }
}

class DashboardViewSwitch extends StatelessWidget {
  const DashboardViewSwitch({
    super.key,
    required this.showMovements,
    required this.onChanged,
  });

  final bool showMovements;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: panelSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: DashboardSwitchItem(
              selected: !showMovements,
              icon: Icons.apartment_rounded,
              label: 'الفروع',
              onTap: () => onChanged(false),
            ),
          ),
          Expanded(
            child: DashboardSwitchItem(
              selected: showMovements,
              icon: Icons.swap_horiz_rounded,
              label: 'الحركات',
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class DashboardSwitchItem extends StatelessWidget {
  const DashboardSwitchItem({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? brandColor : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: selected ? Colors.white : mutedInk),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : inkColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DashboardSummary extends StatelessWidget {
  const DashboardSummary({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: mutedInk, fontSize: 12)),
                Text(value, style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BranchTodayPage extends StatefulWidget {
  const BranchTodayPage({super.key, required this.branch});

  final BranchStatus branch;

  @override
  State<BranchTodayPage> createState() => _BranchTodayPageState();
}

class _BranchTodayPageState extends State<BranchTodayPage> {
  late Future<BranchTodayData> future;
  BranchTodayData? latestData;
  RealtimeChannel? attendanceChannel;
  Timer? refreshTimer;
  bool refreshing = false;

  @override
  void initState() {
    super.initState();
    future = loadAndRemember();
    attendanceChannel = supabase.channel('branch-today-${widget.branch.branchNum}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_attendance_logs',
        callback: (_) => reloadFromChange(),
      ).subscribe();
    refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      reloadFromChange();
    });
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    if (attendanceChannel != null) supabase.removeChannel(attendanceChannel!);
    super.dispose();
  }

  void reloadFromChange() {
    if (!mounted) return;
    setState(() {
      future = loadAndRemember();
    });
  }

  Future<void> refresh() async {
    if (refreshing) return;
    final refreshed = loadAndRemember();
    setState(() {
      refreshing = true;
      future = refreshed;
    });
    try {
      await refreshed;
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<BranchTodayData> loadAndRemember() async {
    final loaded = await loadData();
    latestData = loaded;
    return loaded;
  }

  Future<BranchTodayData> loadData() async {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final nextDay = dayStart.add(const Duration(days: 1));
    final employeeRows = await supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url');
    final employees = employeeRows.cast<Map<String, dynamic>>().map(EmployeeLite.fromRow).toList();
    final employeesById = {for (final employee in employees) employee.id: employee};

    final todayRows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .gte('check_in_at', dayStart.toUtc().toIso8601String())
        .lt('check_in_at', nextDay.toUtc().toIso8601String())
        .order('check_in_at', ascending: false);
    final openRows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .eq('status', 'open')
        .order('check_in_at', ascending: false);

    final rowsById = <String, Map<String, dynamic>>{};
    for (final rawRow in [...todayRows, ...openRows]) {
      final row = Map<String, dynamic>.from(rawRow);
      final fallbackId = '${row['employee_id']}-${row['check_in_at']}';
      rowsById['${row['id'] ?? fallbackId}'] = row;
    }

    final entries = <BranchAttendanceEntry>[];
    for (final row in rowsById.values) {
      final employeeId = row['employee_id'] as String?;
      final rawCheckIn = row['check_in_at'] as String?;
      if (employeeId == null || rawCheckIn == null) continue;
      final knownEmployee = employeesById[employeeId];
      final branchNum = (row['branch_num'] as num?)?.toInt() ?? knownEmployee?.branchNum ?? 0;
      if (branchNum != widget.branch.branchNum) continue;
      final checkIn = DateTime.tryParse(rawCheckIn)?.toLocal();
      if (checkIn == null) continue;
      final rawCheckOut = row['check_out_at'] as String?;
      final checkOut = rawCheckOut == null ? null : DateTime.tryParse(rawCheckOut)?.toLocal();
      if (!checkIn.isBefore(nextDay) || (checkOut != null && !checkOut.isAfter(dayStart))) continue;
      final employee = knownEmployee ??
          EmployeeLite(
            id: employeeId,
            name: 'موظف',
            username: '',
            branchNum: branchNum,
            role: 'employee',
            isActive: false,
          );
      entries.add(
        BranchAttendanceEntry(
          id: '${row['id'] ?? '$employeeId-$rawCheckIn'}',
          employee: employee,
          checkIn: checkIn,
          checkOut: checkOut,
        ),
      );
    }
    entries.sort((a, b) => b.checkIn.compareTo(a.checkIn));

    final grouped = <String, List<BranchAttendanceEntry>>{};
    for (final entry in entries) {
      grouped.putIfAbsent(entry.employee.id, () => <BranchAttendanceEntry>[]).add(entry);
    }
    final employeeDays = grouped.values.map((employeeEntries) {
      employeeEntries.sort((a, b) => b.checkIn.compareTo(a.checkIn));
      return BranchEmployeeDay(employee: employeeEntries.first.employee, entries: employeeEntries);
    }).toList()
      ..sort((a, b) {
        if (a.isPresent != b.isPresent) return a.isPresent ? -1 : 1;
        return a.employee.name.compareTo(b.employee.name);
      });
    return BranchTodayData(entries: entries, employeeDays: employeeDays);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.branch.branchName),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: refreshing ? null : refresh,
            icon: refreshing
                ? const SizedBox(width: 19, height: 19, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: FutureBuilder<BranchTodayData>(
          future: future,
          initialData: latestData,
          builder: (context, snapshot) {
            if (!snapshot.hasData && snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!snapshot.hasData && snapshot.hasError) {
              return ErrorState(message: cleanError(snapshot.error), onRetry: reloadFromChange);
            }
            final data = snapshot.data!;
            final activeEmployees = data.employeeDays.where((employee) => employee.isPresent).toList();
            final totalWorked = data.totalWorkedUntil(now, dayStart);
            return ListView(
              padding: pagePadding,
              children: [
                BranchTodayHeader(
                  branchName: widget.branch.branchName,
                  activeCount: data.activeCount,
                  employeeCount: data.employeeCount,
                  totalWorked: totalWorked,
                ),
                const SizedBox(height: 18),
                const SectionHeader(title: 'الموجودون الآن'),
                const SizedBox(height: 8),
                if (activeEmployees.isEmpty)
                  const Card(
                    child: EmptyState(icon: Icons.storefront_outlined, text: 'لا يوجد موظفون داخل الفرع الآن'),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < activeEmployees.length; i++) ...[
                          BranchActiveEmployeeTile(employeeDay: activeEmployees[i], dayStart: dayStart),
                          if (i != activeEmployees.length - 1) const Divider(indent: 66),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                const SectionHeader(title: 'سجل دوام اليوم'),
                const SizedBox(height: 8),
                if (data.employeeDays.isEmpty)
                  const Card(
                    child: EmptyState(icon: Icons.event_busy_rounded, text: 'لم تُسجل حركات دوام في هذا الفرع اليوم'),
                  )
                else
                  ...data.employeeDays.map(
                    (employeeDay) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: BranchEmployeeDayCard(employeeDay: employeeDay, dayStart: dayStart),
                    ),
                  ),
                const SizedBox(height: 80),
              ],
            );
          },
        ),
      ),
    );
  }
}

class BranchTodayHeader extends StatelessWidget {
  const BranchTodayHeader({
    super.key,
    required this.branchName,
    required this.activeCount,
    required this.employeeCount,
    required this.totalWorked,
  });

  final String branchName;
  final int activeCount;
  final int employeeCount;
  final Duration totalWorked;

  @override
  Widget build(BuildContext context) {
    final isOpen = activeCount > 0;
    final statusColor = isOpen ? successColor : dangerColor;
    return Card(
      color: isOpen ? successSurface.withValues(alpha: 0.42) : panelSurface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                BranchLogo(branchName: branchName, size: 64),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(branchName, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          StatusDot(color: statusColor, size: 8),
                          const SizedBox(width: 6),
                          Text(isOpen ? 'الفرع مفتوح الآن' : 'الفرع مغلق الآن', style: TextStyle(color: statusColor, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: BranchTodayMetric(label: 'الموجودون', value: '$activeCount', icon: Icons.groups_rounded)),
                const SizedBox(width: 8),
                Expanded(child: BranchTodayMetric(label: 'سجلوا اليوم', value: '$employeeCount', icon: Icons.how_to_reg_rounded)),
                const SizedBox(width: 8),
                Expanded(child: BranchTodayMetric(label: 'ساعات اليوم', value: formatDurationCompact(totalWorked), icon: Icons.schedule_rounded)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class BranchTodayMetric extends StatelessWidget {
  const BranchTodayMetric({super.key, required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10),
      decoration: BoxDecoration(
        color: panelSurface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: brandColor),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: mutedInk, fontSize: 10)),
        ],
      ),
    );
  }
}

class BranchActiveEmployeeTile extends StatelessWidget {
  const BranchActiveEmployeeTile({super.key, required this.employeeDay, required this.dayStart});

  final BranchEmployeeDay employeeDay;
  final DateTime dayStart;

  @override
  Widget build(BuildContext context) {
    final openEntry = employeeDay.entries.firstWhere((entry) => entry.isOpen);
    final worked = employeeDay.workedUntil(DateTime.now(), dayStart);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      leading: EmployeeAvatar(name: employeeDay.employee.name, imageUrl: employeeDay.employee.avatarUrl),
      title: Text(employeeDay.employee.name, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('دخل الساعة ${formatTime(openEntry.checkIn)}', style: const TextStyle(color: mutedInk)),
      trailing: StatusPill(label: formatDurationCompact(worked), color: successColor),
    );
  }
}

class BranchEmployeeDayCard extends StatelessWidget {
  const BranchEmployeeDayCard({super.key, required this.employeeDay, required this.dayStart});

  final BranchEmployeeDay employeeDay;
  final DateTime dayStart;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final worked = employeeDay.workedUntil(now, dayStart);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                EmployeeAvatar(name: employeeDay.employee.name, imageUrl: employeeDay.employee.avatarUrl),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(employeeDay.employee.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(
                        employeeDay.isPresent ? 'موجود داخل الفرع الآن' : 'أنهى دوامه في الفرع',
                        style: TextStyle(color: employeeDay.isPresent ? successColor : mutedInk, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                StatusPill(
                  label: formatDurationCompact(worked),
                  color: employeeDay.isPresent ? successColor : brandColor,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 9),
            for (final entry in employeeDay.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    const Icon(Icons.login_rounded, size: 18, color: successColor),
                    const SizedBox(width: 6),
                    Text('دخول ${formatTime(entry.checkIn)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 10),
                    Icon(Icons.logout_rounded, size: 18, color: entry.isOpen ? mutedInk : dangerColor),
                    const SizedBox(width: 6),
                    Text(
                      entry.isOpen ? 'حتى الآن' : 'خروج ${formatTime(entry.checkOut!)}',
                      style: const TextStyle(fontSize: 12, color: mutedInk),
                    ),
                    const Spacer(),
                    Text(
                      formatDurationCompact(entry.workedUntil(now, dayStart)),
                      style: const TextStyle(color: brandColor, fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  Map<String, dynamic>? openLog;
  List<Movement> recent = [];
  Map<int, BranchOption> branches = {};
  bool loading = true;
  String? message;
  String? error;

  @override
  void initState() {
    super.initState();
    loadOpenLog();
  }

  Future<void> loadOpenLog() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      branches = await loadAppBranchesMap();
      final rows = await supabase
          .from('ansar_attendance_logs')
          .select()
          .eq('employee_id', widget.session.id)
          .order('check_in_at', ascending: false)
          .limit(10);
      final openRows = rows.where((row) => row['status'] == 'open').toList();
      openLog = openRows.isEmpty ? null : openRows.first;
      recent = buildMovementsFromRows(
        rows,
        {widget.session.id: EmployeeLite.fromSession(widget.session)},
        branches,
      ).take(8).toList();
      setState(() => loading = false);
    } catch (e) {
      setState(() {
        error = cleanError(e);
        loading = false;
      });
    }
  }

  Future<void> checkIn() async {
    await supabase.from('ansar_attendance_logs').insert({
      'employee_id': widget.session.id,
      'branch_num': widget.session.branchNum,
      'check_in_at': DateTime.now().toUtc().toIso8601String(),
      'status': 'open',
    });
    setState(() => message = 'تم تسجيل الدخول إلى العمل');
    await loadOpenLog();
  }

  Future<void> checkOut() async {
    if (openLog == null) return;
    await supabase.from('ansar_attendance_logs').update({
      'check_out_at': DateTime.now().toUtc().toIso8601String(),
      'status': 'closed',
    }).eq('id', openLog!['id']);
    setState(() => message = 'تم تسجيل الخروج من العمل');
    await loadOpenLog();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return ErrorState(message: error!, onRetry: loadOpenLog);

    final isWorking = openLog != null;
    final branchName = branchLabel(branches, widget.session.branchNum);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Icon(
                  isWorking ? Icons.work_history_rounded : Icons.work_off_rounded,
                  size: 64,
                  color: isWorking ? Colors.green : Colors.grey,
                ),
                const SizedBox(height: 12),
                Text(
                  isWorking ? 'أنت داخل العمل الآن' : 'لا يوجد دوام مفتوح',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(branchName, style: const TextStyle(color: Colors.black54)),
                if (message != null) ...[
                  const SizedBox(height: 12),
                  Text(message!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: isWorking ? null : checkIn,
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('دخول'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isWorking ? checkOut : null,
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('خروج'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const SectionHeader(title: 'حركاتي الأخيرة'),
        if (recent.isEmpty)
          const EmptyState(icon: Icons.history_rounded, text: 'لا توجد حركات سابقة')
        else
          ...recent.map((movement) => MovementTile(movement: movement)),
      ],
    );
  }
}

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  int days = 30;
  int? selectedBranch;
  String? selectedEmployeeId;
  late Future<ReportData> future;
  ReportData? latestReport;

  @override
  void initState() {
    super.initState();
    selectedBranch = widget.session.isAdmin ? null : widget.session.branchNum;
    selectedEmployeeId = widget.session.isAdmin || widget.session.isBranchManager ? null : widget.session.id;
    future = loadAndRememberReports();
  }

  Future<ReportData> loadAndRememberReports() async {
    final loaded = await loadReports();
    latestReport = loaded;
    return loaded;
  }

  Future<ReportData> loadReports() async {
    final branches = await loadAppBranchesMap();
    var employees = await loadEmployeesForScope(widget.session, includeInactive: false);
    if (selectedBranch != null) {
      employees = employees.where((employee) => employee.branchNum == selectedBranch).toList();
    }
    final availableEmployees = List<EmployeeLite>.from(employees)
      ..sort((a, b) => a.name.compareTo(b.name));
    if (selectedEmployeeId != null) {
      employees = employees.where((employee) => employee.id == selectedEmployeeId).toList();
    }

    final employeeById = {for (final employee in employees) employee.id: employee};
    final sinceUtc = DateTime.now().subtract(Duration(days: days)).toUtc();
    final rows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .gte('check_in_at', sinceUtc.toIso8601String())
        .order('check_in_at', ascending: false);

    final hoursByEmployee = <String, double>{};
    final daysByEmployee = <String, Set<String>>{};
    final openByEmployee = <String, int>{};
    final dailyHours = <String, double>{};
    var totalHours = 0.0;
    var openLogs = 0;
    var closedLogs = 0;

    for (final row in rows) {
      final employeeId = row['employee_id'] as String?;
      if (employeeId == null || !employeeById.containsKey(employeeId)) continue;
      final checkInValue = row['check_in_at'] as String?;
      if (checkInValue == null) continue;
      final checkIn = DateTime.parse(checkInValue).toLocal();
      final checkOut = row['check_out_at'] == null
          ? DateTime.now()
          : DateTime.parse(row['check_out_at'] as String).toLocal();
      final hours = checkOut.difference(checkIn).inMinutes / 60;
      if (hours <= 0 || hours > 24) continue;

      final dayKey = formatDateKey(checkIn);
      totalHours += hours;
      dailyHours[dayKey] = (dailyHours[dayKey] ?? 0) + hours;
      hoursByEmployee[employeeId] = (hoursByEmployee[employeeId] ?? 0) + hours;
      daysByEmployee.putIfAbsent(employeeId, () => <String>{}).add(formatDateKey(checkIn));

      if (row['status'] == 'open') {
        openLogs++;
        openByEmployee[employeeId] = (openByEmployee[employeeId] ?? 0) + 1;
      } else {
        closedLogs++;
      }
    }

    final durations = hoursByEmployee.entries
        .map(
          (entry) => EmployeeDuration(
            employee: employeeById[entry.key]!,
            hours: entry.value,
            days: daysByEmployee[entry.key]?.length ?? 0,
            openLogs: openByEmployee[entry.key] ?? 0,
          ),
        )
        .toList()
      ..sort((a, b) => b.hours.compareTo(a.hours));

    return ReportData(
      branches: branches,
      employees: employees,
      availableEmployees: availableEmployees,
      durations: durations,
      dailyHours: dailyHours,
      totalHours: totalHours,
      openLogs: openLogs,
      closedLogs: closedLogs,
    );
  }

  void reload() {
    setState(() {
      future = loadAndRememberReports();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReportData>(
      future: future,
      initialData: latestReport,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return ErrorState(message: cleanError(snapshot.error), onRetry: reload);
        }
        final data = snapshot.data!;
        final topEmployee = data.durations.isEmpty ? null : data.durations.first;
        final selectedBranchName = selectedBranch == null ? 'كل الفروع' : branchLabel(data.branches, selectedBranch!);
        var selectedEmployeeName =
            widget.session.isAdmin || widget.session.isBranchManager ? 'كل الموظفين' : widget.session.name;
        if (selectedEmployeeId != null) {
          final matches = data.employees.where((employee) => employee.id == selectedEmployeeId).toList();
          selectedEmployeeName = matches.isEmpty ? 'موظف محدد' : matches.first.name;
        }
        return ListView(
          key: const PageStorageKey('reports-list'),
          padding: pagePadding,
          children: [
            const PageHeading(
              title: 'التقارير',
              subtitle: 'حلّل الدوام والحضور حسب الفترة والفرع والموظف',
              icon: Icons.insert_chart_outlined_rounded,
            ),
            ReportFilterPanel(
              days: days,
              branches: data.branches,
              employees: data.availableEmployees,
              selectedBranch: selectedBranch,
              selectedEmployeeId: selectedEmployeeId,
              showBranchFilter: widget.session.isAdmin,
              showEmployeeFilter: widget.session.isAdmin || widget.session.isBranchManager,
              onDaysChanged: (value) {
                days = value;
                reload();
              },
              onBranchChanged: (value) {
                selectedBranch = value;
                selectedEmployeeId = null;
                reload();
              },
              onEmployeeChanged: (value) {
                selectedEmployeeId = value;
                reload();
              },
            ),
            const SizedBox(height: 12),
            ReportInsightCard(
              days: days,
              branchName: selectedBranchName,
              employeeName: selectedEmployeeName,
              topEmployee: topEmployee,
              dailyHours: data.dailyHours,
              employeesWithHours: data.durations.length,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    title: 'إجمالي الساعات',
                    value: data.totalHours.toStringAsFixed(1),
                    icon: Icons.timer_rounded,
                    color: brandColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    title: 'متوسط الوردية',
                    value: data.averageHours.toStringAsFixed(1),
                    icon: Icons.speed_rounded,
                    color: accentColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    title: 'سجلات مغلقة',
                    value: '${data.closedLogs}',
                    icon: Icons.done_all_rounded,
                    color: successColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    title: 'دوام مفتوح',
                    value: '${data.openLogs}',
                    icon: Icons.pending_actions_rounded,
                    color: dangerColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'الساعات حسب الأيام'),
            if (data.dailyHours.isEmpty)
              const EmptyState(icon: Icons.bar_chart_rounded, text: 'لا توجد بيانات للفترة المحددة')
            else
              SizedBox(height: 280, child: DailyHoursChart(values: data.dailyHours)),
            const SizedBox(height: 16),
            const SectionHeader(title: 'ترتيب الموظفين'),
            if (data.durations.isEmpty)
              const EmptyState(icon: Icons.people_outline_rounded, text: 'لا توجد سجلات مطابقة')
            else
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < data.durations.length; i++) ...[
                      DurationListTile(item: data.durations[i], rank: i + 1),
                      if (i != data.durations.length - 1) const Divider(indent: 68),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class ReportFilterPanel extends StatelessWidget {
  const ReportFilterPanel({
    super.key,
    required this.days,
    required this.branches,
    required this.employees,
    required this.selectedBranch,
    required this.selectedEmployeeId,
    required this.showBranchFilter,
    required this.showEmployeeFilter,
    required this.onDaysChanged,
    required this.onBranchChanged,
    required this.onEmployeeChanged,
  });

  final int days;
  final Map<int, BranchOption> branches;
  final List<EmployeeLite> employees;
  final int? selectedBranch;
  final String? selectedEmployeeId;
  final bool showBranchFilter;
  final bool showEmployeeFilter;
  final ValueChanged<int> onDaysChanged;
  final ValueChanged<int?> onBranchChanged;
  final ValueChanged<String?> onEmployeeChanged;

  @override
  Widget build(BuildContext context) {
    final branchOptions = branches.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.tune_rounded, color: brandColor),
                SizedBox(width: 8),
                Text('نطاق التقرير', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 13),
            Row(
              children: [
                for (final value in const [7, 30, 60]) ...[
                  Expanded(
                    child: ReportPeriodOption(
                      days: value,
                      selected: days == value,
                      onTap: () => onDaysChanged(value),
                    ),
                  ),
                  if (value != 60) const SizedBox(width: 7),
                ],
              ],
            ),
            if (showBranchFilter) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                key: ValueKey('branch-${selectedBranch ?? 'all'}'),
                initialValue: selectedBranch,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'الفرع',
                  prefixIcon: Icon(Icons.storefront_rounded),
                ),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('كل الفروع')),
                  ...branchOptions.map(
                    (branch) => DropdownMenuItem<int?>(
                      value: branch.number,
                      child: Text(branch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: onBranchChanged,
              ),
            ],
            if (showEmployeeFilter) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                key: ValueKey('employee-${selectedEmployeeId ?? 'all'}-${employees.length}'),
                initialValue: selectedEmployeeId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'الموظف',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('كل الموظفين')),
                  ...employees.map(
                    (employee) => DropdownMenuItem<String?>(
                      value: employee.id,
                      child: Text(employee.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: onEmployeeChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ReportPeriodOption extends StatelessWidget {
  const ReportPeriodOption({super.key, required this.days, required this.selected, required this.onTap});

  final int days;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? brandColor : softSurface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? brandColor : borderColor),
          ),
          child: Text(
            days == 7 ? '7 أيام' : '$days يوم',
            style: TextStyle(
              color: selected ? Colors.white : inkColor,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class ReportInsightCard extends StatelessWidget {
  const ReportInsightCard({
    super.key,
    required this.days,
    required this.branchName,
    required this.employeeName,
    required this.topEmployee,
    required this.dailyHours,
    required this.employeesWithHours,
  });

  final int days;
  final String branchName;
  final String employeeName;
  final EmployeeDuration? topEmployee;
  final Map<String, double> dailyHours;
  final int employeesWithHours;

  @override
  Widget build(BuildContext context) {
    MapEntry<String, double>? busiestDay;
    for (final entry in dailyHours.entries) {
      if (busiestDay == null || entry.value > busiestDay.value) busiestDay = entry;
    }
    return Card(
      color: brandColor.withValues(alpha: 0.07),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                InfoChip(icon: Icons.date_range_rounded, label: 'آخر $days يوم'),
                InfoChip(icon: Icons.storefront_rounded, label: branchName),
                InfoChip(icon: Icons.person_search_rounded, label: employeeName),
              ],
            ),
            const SizedBox(height: 14),
            if (topEmployee == null)
              const Text('لا توجد ساعات دوام ضمن النطاق المحدد', style: TextStyle(color: mutedInk))
            else
              Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      EmployeeAvatar(
                        name: topEmployee!.employee.name,
                        imageUrl: topEmployee!.employee.avatarUrl,
                        radius: 27,
                      ),
                      const Positioned(
                        left: -4,
                        bottom: -3,
                        child: CircleAvatar(
                          radius: 11,
                          backgroundColor: accentColor,
                          child: Icon(Icons.emoji_events_rounded, size: 13, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('الأطول دواماً', style: TextStyle(color: mutedInk, fontSize: 12)),
                        const SizedBox(height: 3),
                        Text(topEmployee!.employee.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        Text('${topEmployee!.days} أيام حضور', style: const TextStyle(color: mutedInk, fontSize: 11)),
                      ],
                    ),
                  ),
                  StatusPill(label: '${topEmployee!.hours.toStringAsFixed(1)} س', color: brandColor),
                ],
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ReportMiniInsight(
                    icon: Icons.calendar_month_rounded,
                    label: 'اليوم الأعلى',
                    value: busiestDay == null
                        ? '-'
                        : '${reportDayLabel(busiestDay.key)} · ${busiestDay.value.toStringAsFixed(1)} س',
                    color: accentColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ReportMiniInsight(
                    icon: Icons.groups_rounded,
                    label: 'موظفون بسجلات',
                    value: '$employeesWithHours',
                    color: successColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ReportMiniInsight extends StatelessWidget {
  const ReportMiniInsight({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: panelSurface.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: mutedInk, fontSize: 10)),
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class QueriesPage extends StatefulWidget {
  const QueriesPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<QueriesPage> createState() => _QueriesPageState();
}

class _QueriesPageState extends State<QueriesPage> {
  final search = TextEditingController();
  late final TextEditingController startDate;
  late final TextEditingController endDate;
  Future<Object>? future;
  Timer? queryDebounce;
  int queryMode = 0;
  String selectedSalesBooks = 'all';

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final todayKey = formatDateKey(today);
    startDate = TextEditingController(text: todayKey);
    endDate = TextEditingController(text: todayKey);
    unawaited(warmQueriesCache());
  }

  @override
  void dispose() {
    queryDebounce?.cancel();
    search.dispose();
    startDate.dispose();
    endDate.dispose();
    super.dispose();
  }

  Future<List<ProductResult>> runSearch() async {
    final value = search.text.trim();
    if (value.isEmpty) return [];

    final productRows = await searchProductsLikeLegacy(value, limit: 60);

    final branches = await loadLegacyBranchesMap();
    final matNums = productRows
        .take(40)
        .map((product) => (product['mat_num'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    final stockRows = matNums.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase
            .from('product_stock')
            .select('mat_num, sto_num, quantity')
            .inFilter('mat_num', matNums);
    final stockByMat = <int, List<StockResult>>{};
    for (final row in stockRows.cast<Map<String, dynamic>>()) {
      final matNum = (row['mat_num'] as num?)?.toInt();
      final branchNum = (row['sto_num'] as num?)?.toInt();
      if (matNum == null || branchNum == null) continue;
      stockByMat.putIfAbsent(matNum, () => <StockResult>[]).add(
            StockResult(
              branchName: branchLabel(branches, branchNum),
              quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            ),
          );
    }
    final results = <ProductResult>[];
    for (final product in productRows.take(40)) {
      final matNum = (product['mat_num'] as num?)?.toInt();
      if (matNum == null) continue;
      final stock = stockByMat[matNum] ?? <StockResult>[];
      stock.sort((a, b) => b.quantity.compareTo(a.quantity));
      results.add(ProductResult(product: product, stock: stock));
    }
    return results;
  }

  void submitSearch() {
    setState(() {
      if (queryMode == 0) future = runSearch();
      if (queryMode == 1) future = runAccountsSearch();
      if (queryMode == 2) future = runCashSummary();
      if (queryMode == 3) future = runDailySales();
    });
  }

  void queueSearch() {
    queryDebounce?.cancel();
    final value = search.text.trim();
    if (queryMode != 0 && queryMode != 1) return;
    final minLength = queryMode == 0 ? 2 : 1;
    if (value.length < minLength) {
      setState(() => future = null);
      return;
    }
    queryDebounce = Timer(const Duration(milliseconds: 320), submitSearch);
  }

  Future<List<Map<String, dynamic>>> runAccountsSearch() async {
    final value = search.text.trim();
    if (value.isEmpty) return [];
    final numeric = int.tryParse(value);
    final accounts = await loadAccountsCached();
    final normalized = normalizeSearch(value);
    final results = accounts.where((account) {
      final accountNum = (account['num'] as num?)?.toInt();
      final name = normalizeSearch(account['name'] as String? ?? '');
      if (numeric != null) return accountNum?.toString().contains(value) == true;
      return name.contains(normalized);
    }).take(40).toList();
    return results;
  }

  Future<List<Map<String, dynamic>>> runCashSummary() async {
    const cashBoxes = [181, 1872, 1873, 1876];
    final rows = await supabase
        .from('accounts')
        .select('num, name, ras')
        .inFilter('num', cashBoxes)
        .order('num', ascending: true);
    return rows.cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> runDailySales() async {
    var query = supabase
        .from('bills_full')
        .select('book, bnum, date, accnum, totalvalue, remark, kind')
        .eq('kind', 0)
        .gte('date', startDate.text)
        .lte('date', endDate.text);
    if (selectedSalesBooks != 'all') {
      final books = selectedSalesBooks.split(',').map(int.parse).toList();
      query = books.length == 1 ? query.eq('book', books.first) : query.inFilter('book', books);
    }
    final rows = await query.order('date', ascending: false).order('bnum', ascending: false).limit(100);
    final accounts = {
      for (final account in await loadAccountsCached()) (account['num'] as num?)?.toInt(): account['name'] as String? ?? ''
    };
    return rows.cast<Map<String, dynamic>>().map((bill) {
      final accNum = (bill['accnum'] as num?)?.toInt();
      return {
        ...bill,
        'account_name': accNum == null ? 'زبون عابر' : accounts[accNum] ?? 'حساب $accNum',
      };
    }).toList();
  }

  Future<void> openAccountStatement(Map<String, dynamic> account) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: AccountStatementPage(account: account),
        ),
      ),
    );
  }

  Future<void> openSalesDetails(Map<String, dynamic> bill) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: SalesBillDetailsPage(bill: bill),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const PageStorageKey('queries-list'),
      padding: pagePadding,
      children: [
        const PageHeading(
          title: 'الاستعلامات',
          subtitle: 'وصول سريع إلى الكتب والحسابات والصناديق والمبيعات',
          icon: Icons.manage_search_rounded,
        ),
        _QueryModeTabs(
          selected: queryMode,
          onChanged: (value) {
            queryDebounce?.cancel();
            setState(() {
              queryMode = value;
              future = null;
              search.clear();
            });
            if (queryMode == 2 || queryMode == 3) submitSearch();
          },
        ),
        const SizedBox(height: 12),
        if (queryMode == 0 || queryMode == 1)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: search,
                autofocus: false,
                decoration: InputDecoration(
                  labelText: queryMode == 0 ? 'ابحث عن كتاب' : 'ابحث عن حساب',
                  hintText: queryMode == 0 ? 'اكتب العنوان أو رقم المادة' : 'اكتب الاسم أو رقم الحساب',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح البحث',
                          onPressed: () {
                            search.clear();
                            setState(() => future = null);
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
                onChanged: (_) {
                  setState(() {});
                  queueSearch();
                },
                onSubmitted: (_) => submitSearch(),
              ),
            ),
          ),
        if (queryMode == 1 || queryMode == 3) ...[
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('الفترة الزمنية', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: startDate,
                    decoration: const InputDecoration(
                      labelText: 'من تاريخ',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: endDate,
                    decoration: const InputDecoration(
                      labelText: 'إلى تاريخ',
                      prefixIcon: Icon(Icons.event_available_outlined),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (queryMode == 3) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: selectedSalesBooks,
            decoration: const InputDecoration(labelText: 'الفرع'),
            items: salesBookOptions
                .map((option) => DropdownMenuItem(value: option.value, child: Text(option.label)))
                .toList(),
            onChanged: (value) {
              setState(() {
                selectedSalesBooks = value ?? 'all';
                future = runDailySales();
              });
            },
          ),
        ],
        if (queryMode == 2 || queryMode == 3) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: submitSearch,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('تحديث'),
          ),
        ],
        const SizedBox(height: 12),
        if (future == null)
          const EmptyState(icon: Icons.manage_search_rounded, text: 'اكتب كلمة بحث لعرض الكتب والمخزون')
        else if (queryMode == 0)
          FutureBuilder<List<ProductResult>>(
            future: future as Future<List<ProductResult>>,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ));
              }
              if (snapshot.hasError) {
                return ErrorState(message: cleanError(snapshot.error), onRetry: submitSearch);
              }
              final results = snapshot.data!;
              if (results.isEmpty) {
                return const EmptyState(icon: Icons.search_off_rounded, text: 'لا توجد نتائج مطابقة');
              }
              return Column(children: results.map((result) => ProductResultCard(result: result)).toList());
            },
          )
        else if (queryMode == 1)
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future as Future<List<Map<String, dynamic>>>,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ));
              }
              if (snapshot.hasError) {
                return ErrorState(message: cleanError(snapshot.error), onRetry: submitSearch);
              }
              final results = snapshot.data!;
              if (results.isEmpty) {
                return const EmptyState(icon: Icons.search_off_rounded, text: 'لا توجد نتائج مطابقة');
              }
              return Column(
                children: results
                    .map(
                      (account) => Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.account_circle_rounded)),
                          title: Text(account['name'] as String? ?? 'بدون اسم'),
                          subtitle: Text('رقم ${account['num']} · رصيد ${account['ras'] ?? '-'}'),
                          trailing: Text('${account['owner'] ?? ''}'),
                          onTap: () => openAccountStatement(account),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          )
        else if (queryMode == 2)
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future as Future<List<Map<String, dynamic>>>,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ));
              }
              if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: submitSearch);
              final rows = snapshot.data!;
              final total = rows.fold<double>(0, (sum, row) => sum + ((row['ras'] as num?)?.toDouble() ?? 0));
              return Column(
                children: [
                  StatTile(title: 'إجمالي الصناديق', value: total.toStringAsFixed(0), icon: Icons.payments_rounded, color: brandColor),
                  ...rows.map((box) => Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.point_of_sale_rounded)),
                          title: Text(box['name'] as String? ?? 'صندوق ${box['num']}'),
                          subtitle: Text('رقم ${box['num']}'),
                          trailing: Text('${box['ras'] ?? 0}'),
                        ),
                      )),
                ],
              );
            },
          )
        else
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future as Future<List<Map<String, dynamic>>>,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ));
              }
              if (snapshot.hasError) {
                return ErrorState(message: cleanError(snapshot.error), onRetry: submitSearch);
              }
              final results = snapshot.data!;
              if (results.isEmpty) {
                return const EmptyState(icon: Icons.search_off_rounded, text: 'لا توجد مبيعات اليوم');
              }
              return Column(
                children: results
                    .map(
                      (bill) => Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.receipt_long_rounded)),
                          title: Text('فاتورة ${bill['bnum']} · ${salesBookName(bill['book'])}'),
                          subtitle: Text('${bill['account_name']} · ${paymentLabelFromRemark(bill['remark']).text} · ${bill['date']}'),
                          trailing: Text(formatMoneyValue(bill['totalvalue'])),
                          onTap: () => openSalesDetails(bill),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
      ],
    );
  }
}

class _QueryModeTabs extends StatelessWidget {
  const _QueryModeTabs({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const items = [
      (value: 0, icon: Icons.menu_book_rounded, label: 'الكتب والمخزون'),
      (value: 1, icon: Icons.account_balance_wallet_rounded, label: 'الحسابات'),
      (value: 2, icon: Icons.payments_rounded, label: 'الصناديق'),
      (value: 3, icon: Icons.receipt_long_rounded, label: 'المبيعات اليومية'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 8) / 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items.map((item) {
            final active = selected == item.value;
            return SizedBox(
              width: width,
              height: 50,
              child: Material(
                color: active ? brandColor : panelSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: active ? brandColor : borderColor),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onChanged(item.value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(item.icon, size: 19, color: active ? Colors.white : brandColor),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: active ? Colors.white : inkColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class ProductResult {
  ProductResult({required this.product, required this.stock});

  final Map<String, dynamic> product;
  final List<StockResult> stock;
}

class AccountStatementPage extends StatefulWidget {
  const AccountStatementPage({super.key, required this.account});

  final Map<String, dynamic> account;

  @override
  State<AccountStatementPage> createState() => _AccountStatementPageState();
}

class _AccountStatementPageState extends State<AccountStatementPage> {
  late final TextEditingController startDate;
  late final TextEditingController endDate;
  late Future<List<Map<String, dynamic>>> future;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    endDate = TextEditingController(text: formatDateKey(today));
    startDate = TextEditingController(text: formatDateKey(DateTime(today.year, today.month, 1)));
    future = loadEntries();
  }

  Future<List<Map<String, dynamic>>> loadEntries() async {
    final rows = await supabase
        .from('account_entries')
        .select('num, item, kind, date, remark, acc_num2, cash, billnum')
        .eq('acc_num', widget.account['num'])
        .gte('date', startDate.text)
        .lte('date', endDate.text)
        .order('date', ascending: true)
        .order('num', ascending: true)
        .order('item', ascending: true);
    final accounts = {
      for (final account in await loadAccountsCached()) (account['num'] as num?)?.toInt(): account['name'] as String? ?? ''
    };
    return rows.cast<Map<String, dynamic>>().map((entry) {
      final otherNum = (entry['acc_num2'] as num?)?.toInt();
      return {
        ...entry,
        'other_account_name': otherNum == null ? '-' : accounts[otherNum] ?? 'حساب $otherNum',
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.account['name'] as String? ?? 'كشف حساب')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(child: TextField(controller: startDate, decoration: const InputDecoration(labelText: 'من تاريخ'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: endDate, decoration: const InputDecoration(labelText: 'إلى تاريخ'))),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => setState(() {
              future = loadEntries();
            }),
            icon: const Icon(Icons.search_rounded),
            label: const Text('عرض الكشف'),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
              }
              if (snapshot.hasError) {
                return ErrorState(
                  message: cleanError(snapshot.error),
                  onRetry: () => setState(() {
                    future = loadEntries();
                  }),
                );
              }
              final rows = snapshot.data!;
              if (rows.isEmpty) return const EmptyState(icon: Icons.receipt_long_rounded, text: 'لا توجد حركات ضمن الفترة');
              var running = 0.0;
              return Column(
                children: rows.map((entry) {
                  final cash = (entry['cash'] as num?)?.toDouble() ?? 0;
                  running += cash;
                  return Card(
                    child: ListTile(
                      title: Text(entry['remark'] as String? ?? 'حركة'),
                      subtitle: Text('${entry['date']} · سند ${entry['num'] ?? '-'} · مقابل ${entry['other_account_name'] ?? '-'}'),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(cash.toStringAsFixed(0), style: TextStyle(color: cash < 0 ? Colors.red : Colors.green)),
                          Text('رصيد ${running.toStringAsFixed(0)}', style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class SalesBillDetailsPage extends StatefulWidget {
  const SalesBillDetailsPage({super.key, required this.bill});

  final Map<String, dynamic> bill;

  @override
  State<SalesBillDetailsPage> createState() => _SalesBillDetailsPageState();
}

class _SalesBillDetailsPageState extends State<SalesBillDetailsPage> {
  late Future<SalesBillDetailsData> future;

  @override
  void initState() {
    super.initState();
    future = loadItems();
  }

  Future<SalesBillDetailsData> loadItems() async {
    final rows = await supabase
        .from('bill_items_full')
        .select('item, matnum, quantity, price, value, remarki')
        .eq('book', widget.bill['book'])
        .eq('bnum', widget.bill['bnum'])
        .eq('kind', 0)
        .order('item', ascending: true);
    final items = rows.cast<Map<String, dynamic>>();
    final matNums = items.map((row) => (row['matnum'] as num?)?.toInt()).whereType<int>().toSet().toList();
    final products = matNums.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase.from('products').select('mat_num, name').inFilter('mat_num', matNums);
    final names = {
      for (final product in products.cast<Map<String, dynamic>>())
        (product['mat_num'] as num).toInt(): product['name'] as String? ?? ''
    };
    final branches = await loadLegacyBranchesMap();
    return SalesBillDetailsData(
      branches: branches,
      items: items.map((item) => {...item, 'product_name': names[(item['matnum'] as num?)?.toInt()]}).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('فاتورة ${widget.bill['bnum']}')),
      body: FutureBuilder<SalesBillDetailsData>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: cleanError(snapshot.error),
              onRetry: () => setState(() {
                future = loadItems();
              }),
            );
          }
          final data = snapshot.data!;
          final items = data.items;
          final payment = paymentLabelFromRemark(widget.bill['remark']);
          final stoNum = parseStoNum(widget.bill['remark']);
          final total = (widget.bill['totalvalue'] as num?)?.toDouble() ?? 0;
          final gross = items.fold<double>(
            0,
            (sum, item) =>
                sum + (((item['quantity'] as num?)?.toDouble() ?? 0) * ((item['price'] as num?)?.toDouble() ?? 0)),
          );
          final discount = gross > total && gross > 0 ? gross - total : 0.0;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: brandColor.withValues(alpha: 0.1),
                            child: const Icon(Icons.receipt_long_rounded, color: brandColor),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('فاتورة ${widget.bill['bnum']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                                Text('${widget.bill['account_name'] ?? 'حساب ${widget.bill['accnum']}'}'),
                              ],
                            ),
                          ),
                          Chip(
                            avatar: Icon(payment.isCash ? Icons.payments_rounded : Icons.schedule_rounded, size: 16),
                            label: Text(payment.text),
                          ),
                        ],
                      ),
                      const Divider(height: 22),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          InfoChip(icon: Icons.storefront_rounded, label: salesBookName(widget.bill['book'])),
                          InfoChip(icon: Icons.warehouse_rounded, label: stoNum == null ? 'مستودع غير محدد' : branchLabel(data.branches, stoNum)),
                          InfoChip(icon: Icons.calendar_month_rounded, label: '${widget.bill['date']}'),
                          InfoChip(icon: Icons.summarize_rounded, label: 'الإجمالي ${formatMoneyValue(total)}'),
                          if (discount > 0) InfoChip(icon: Icons.percent_rounded, label: 'حسم ${formatMoneyValue(discount)}'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (items.isEmpty)
                const EmptyState(icon: Icons.inventory_2_outlined, text: 'لا توجد بنود')
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('بنود الفاتورة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const Divider(height: 18),
                        ...items.asMap().entries.map((entry) {
                          final index = entry.key;
                          final item = entry.value;
                          final itemSto = parseStoNum(item['remarki']);
                          return Padding(
                            padding: EdgeInsets.only(bottom: index == items.length - 1 ? 0 : 12),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: softSurface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.black12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item['product_name'] as String? ?? 'مادة ${item['matnum']}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        InfoChip(icon: Icons.numbers_rounded, label: 'الكمية ${formatMoneyValue(item['quantity'])}'),
                                        InfoChip(icon: Icons.sell_rounded, label: 'السعر ${formatMoneyValue(item['price'])}'),
                                        InfoChip(icon: Icons.percent_rounded, label: 'الحسم ${discountDisplay(item)}'),
                                        InfoChip(icon: Icons.summarize_rounded, label: 'القيمة ${formatMoneyValue(item['value'])}'),
                                        InfoChip(
                                          icon: Icons.warehouse_rounded,
                                          label: itemSto == null ? 'مستودع غير محدد' : branchLabel(data.branches, itemSto),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class SalesBillDetailsData {
  SalesBillDetailsData({required this.items, required this.branches});

  final List<Map<String, dynamic>> items;
  final Map<int, BranchOption> branches;
}

class StockResult {
  StockResult({required this.branchName, required this.quantity});

  final String branchName;
  final double quantity;
}

class SalesBookOption {
  const SalesBookOption(this.value, this.label);

  final String value;
  final String label;
}

const salesBookOptions = [
  SalesBookOption('all', 'كل الفروع'),
  SalesBookOption('30', 'ادلب'),
  SalesBookOption('56', 'الباب'),
  SalesBookOption('70', 'الدانا'),
  SalesBookOption('20,21', 'حمص'),
  SalesBookOption('55', 'دمشق'),
];

String salesBookName(Object? book) {
  final value = '$book';
  for (final option in salesBookOptions) {
    if (option.value.split(',').contains(value)) return option.label;
  }
  return 'دفتر $value';
}

class ProductResultCard extends StatelessWidget {
  const ProductResultCard({super.key, required this.result});

  final ProductResult result;

  @override
  Widget build(BuildContext context) {
    final product = result.product;
    final matNum = product['mat_num'];
    final prices = [
      ('سعر الجرد', product['jard_price']),
      ('السعر القائم', product['regular_price']),
      ('سعر المكتبات', product['price1']),
      ('سعر المعاهد', product['price2']),
      ('سعر المفرق', product['price3']),
    ].where((item) => hasVisiblePrice(item.$2)).toList();
    return Card(
      child: ExpansionTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(color: successSurface, shape: BoxShape.circle),
          child: const Icon(Icons.menu_book_outlined, color: brandColor),
        ),
        title: Text(
          product['name'] as String? ?? 'بدون اسم',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          'رقم المادة $matNum · الكمية ${formatMoneyValue(product['quantity'])}',
          style: const TextStyle(color: mutedInk, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (prices.isNotEmpty)
            Container(
              decoration: BoxDecoration(color: softSurface, borderRadius: BorderRadius.circular(8)),
              child: Column(
                children: [
                  for (var i = 0; i < prices.length; i++) ...[
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.sell_outlined, color: brandColor, size: 20),
                      title: Text(prices[i].$1),
                      trailing: Text(
                        formatMoneyValue(prices[i].$2),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (i != prices.length - 1) const Divider(indent: 48),
                  ],
                ],
              ),
            ),
          if (prices.isNotEmpty) const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerRight,
            child: Text('الرصيد حسب الفرع', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 4),
          if (result.stock.isEmpty)
            const Align(
              alignment: Alignment.centerRight,
              child: Text('لا توجد كميات حسب الفروع', style: TextStyle(color: Colors.black54)),
            )
          else
            ...result.stock.map(
                  (stock) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      stock.quantity < 0
                          ? Icons.warning_rounded
                          : stock.quantity > 0
                              ? Icons.storefront_rounded
                              : Icons.storefront_outlined,
                      color: stock.quantity < 0
                          ? Colors.red
                          : stock.quantity > 0
                              ? brandColor
                              : Colors.black38,
                    ),
                    title: Text(stock.branchName),
                    trailing: Text(
                      formatMoneyValue(stock.quantity),
                      style: TextStyle(
                        color: stock.quantity < 0 ? Colors.red : inkColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

bool hasVisiblePrice(Object? value) {
  if (value == null) return false;
  final number = (value as num?)?.toDouble() ?? double.tryParse('$value');
  return number != null && number.abs() > 0.001;
}

class PriceChip extends StatelessWidget {
  const PriceChip({super.key, required this.label, required this.value});

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label: ${formatMoneyValue(value)}'));
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class ManagementPage extends StatefulWidget {
  const ManagementPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: PageHeading(
            title: 'إدارة النظام',
            subtitle: 'الموظفون والفروع وحالة الإشعارات',
            icon: Icons.admin_panel_settings_outlined,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.people_rounded), label: Text('الموظفون')),
              ButtonSegment(value: 1, icon: Icon(Icons.store_rounded), label: Text('الفروع')),
              ButtonSegment(value: 2, icon: Icon(Icons.notifications_active_rounded), label: Text('الإشعارات')),
            ],
            selected: {tab},
            onSelectionChanged: (value) => setState(() => tab = value.first),
          ),
        ),
        Expanded(
          child: tab == 0
              ? EmployeesPage(session: widget.session)
              : tab == 1
                  ? BranchesPage(session: widget.session)
                  : NotificationDiagnosticsPage(session: widget.session),
        ),
      ],
    );
  }
}

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  late Future<EmployeesData> employeesFuture;
  bool employeeBusy = false;

  @override
  void initState() {
    super.initState();
    employeesFuture = loadEmployees();
  }

  Future<EmployeesData> loadEmployees() async {
    final branches = await loadAppBranchesMap();
    final rows = await supabase
        .from('ansar_employees')
        .select()
        .order('created_at', ascending: false);
    return EmployeesData(
      branches: branches,
      employees: rows,
    );
  }

  Future<void> openEmployeeDialog({
    required Map<int, BranchOption> branches,
    Map<String, dynamic>? employee,
  }) async {
    if (branches.isEmpty) {
      showSnack(context, 'أضف فرعا أولا من تبويب الفروع');
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => EmployeeDialog(branches: branches, employee: employee),
    );
    if (result == null) return;

    setState(() => employeeBusy = true);
    try {
      if (employee == null) {
        await supabase.from('ansar_employees').insert({
          ...result,
          'created_by': widget.session.id,
          'is_active': true,
        });
      } else {
        await supabase.from('ansar_employees').update(result).eq('id', employee['id']);
      }
      if (mounted) {
        setState(() {
          employeesFuture = loadEmployees();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => employeeBusy = false);
    }
  }

  Future<void> disableEmployee(Map<String, dynamic> employee) async {
    final confirmed = await confirmDialog(
      context,
      title: 'حذف الموظف',
      message: 'سيتم إخفاء الموظف وتعطيل دخوله مع الحفاظ على سجلات الدوام القديمة.',
    );
    if (!confirmed) return;
    setState(() => employeeBusy = true);
    try {
      await supabase.from('ansar_employees').update({'is_active': false}).eq('id', employee['id']);
      if (mounted) {
        setState(() {
          employeesFuture = loadEmployees();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => employeeBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EmployeesData>(
      future: employeesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: () => setState(() {
              employeesFuture = loadEmployees();
            }),
          );
        }
        final data = snapshot.data!;
        return Scaffold(
          body: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: data.employees.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final employee = data.employees[i];
              final branchNum = (employee['branch_num'] as num?)?.toInt() ?? 0;
              final active = employee['is_active'] != false;
              return ListTile(
                leading: EmployeeAvatar(
                  name: employee['display_name'] ?? employee['full_name'] ?? '',
                  imageUrl: employee['avatar_url'] as String?,
                ),
                title: Text(employee['display_name'] ?? employee['full_name'] ?? ''),
                subtitle: Text('${branchLabel(data.branches, branchNum)} · ${employee['username']}'),
                trailing: PopupMenuButton<String>(
                  onSelected: employeeBusy ? null : (value) {
                    if (value == 'edit') {
                      openEmployeeDialog(branches: data.branches, employee: employee);
                    } else if (value == 'disable') {
                      disableEmployee(employee);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('تعديل')),
                    PopupMenuItem(
                      value: 'disable',
                      enabled: active,
                      child: Text(active ? 'حذف من القائمة' : 'معطل'),
                    ),
                  ],
                ),
              );
            },
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: employeeBusy ? null : () => openEmployeeDialog(branches: data.branches),
            icon: employeeBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_rounded),
            label: Text(employeeBusy ? 'جاري الحفظ' : 'موظف'),
          ),
        );
      },
    );
  }
}

class EmployeesData {
  EmployeesData({required this.branches, required this.employees});

  final Map<int, BranchOption> branches;
  final List<Map<String, dynamic>> employees;
}

class EmployeeDialog extends StatefulWidget {
  const EmployeeDialog({super.key, required this.branches, this.employee});

  final Map<int, BranchOption> branches;
  final Map<String, dynamic>? employee;

  @override
  State<EmployeeDialog> createState() => _EmployeeDialogState();
}

class _EmployeeDialogState extends State<EmployeeDialog> {
  final name = TextEditingController();
  final username = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  final jobTitle = TextEditingController();
  String role = 'employee';
  int? branchNum;

  @override
  void initState() {
    super.initState();
    final employee = widget.employee;
    if (employee != null) {
      name.text = (employee['display_name'] ?? employee['full_name'] ?? '') as String;
      username.text = employee['username'] as String? ?? '';
      phone.text = employee['phone'] as String? ?? '';
      email.text = employee['email'] as String? ?? '';
      jobTitle.text = employee['job_title'] as String? ?? '';
      role = employee['role'] as String? ?? 'employee';
      branchNum = (employee['branch_num'] as num?)?.toInt();
    } else if (widget.branches.isNotEmpty) {
      branchNum = widget.branches.keys.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.employee == null ? 'إضافة موظف' : 'تعديل موظف'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
            TextField(controller: username, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
            TextField(controller: jobTitle, decoration: const InputDecoration(labelText: 'المسمى الوظيفي')),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'الهاتف')),
            TextField(controller: email, decoration: const InputDecoration(labelText: 'البريد')),
            DropdownButtonFormField<int>(
              initialValue: branchNum,
              decoration: const InputDecoration(labelText: 'الفرع'),
              items: widget.branches.values
                  .map((branch) => DropdownMenuItem(value: branch.number, child: Text(branch.label)))
                  .toList(),
              onChanged: (value) => setState(() => branchNum = value),
            ),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: 'الصلاحية'),
              items: const [
                DropdownMenuItem(value: 'employee', child: Text('موظف')),
                DropdownMenuItem(value: 'branch_manager', child: Text('مدير فرع')),
                DropdownMenuItem(value: 'admin', child: Text('مدير عام')),
              ],
              onChanged: (value) => setState(() => role = value ?? 'employee'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: branchNum == null
              ? null
              : () {
                  Navigator.pop(context, {
                    'full_name': name.text.trim(),
                    'display_name': name.text.trim(),
                    'username': username.text.trim(),
                    'phone': emptyToNull(phone.text),
                    'email': emptyToNull(email.text),
                    'job_title': emptyToNull(jobTitle.text),
                    'branch_num': branchNum,
                    'role': role,
                    'can_manage_employees': role == 'admin',
                    'can_manage_all_branches': role == 'admin',
                  });
                },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

class BranchesPage extends StatefulWidget {
  const BranchesPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<BranchesPage> createState() => _BranchesPageState();
}

class _BranchesPageState extends State<BranchesPage> {
  late Future<Map<int, BranchOption>> future;
  bool branchBusy = false;

  @override
  void initState() {
    super.initState();
    future = loadAppBranchesMap();
  }

  Future<void> openBranchDialog([BranchOption? branch]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => BranchDialog(branch: branch),
    );
    if (result == null) return;
    setState(() => branchBusy = true);
    try {
      if (branch == null) {
        await supabase.from('ansar_branches').upsert({
          ...result,
          'is_active': true,
          'created_by': widget.session.id,
        });
      } else {
        await supabase.from('ansar_branches').upsert({
          'sto_num': branch.number,
          'name': result['name'],
          'is_active': true,
          'created_by': widget.session.id,
        });
      }
      if (mounted) {
        setState(() {
          future = loadAppBranchesMap();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => branchBusy = false);
    }
  }

  Future<void> deleteBranch(BranchOption branch) async {
    final confirmed = await confirmDialog(
      context,
      title: 'حذف الفرع',
      message: 'لا تحذف الفرع إذا كان مرتبطا بموظفين أو سجلات. الأفضل تعديله عند الحاجة.',
    );
    if (!confirmed) return;
    setState(() => branchBusy = true);
    try {
      await supabase.from('ansar_branches').upsert({
        'sto_num': branch.number,
        'name': branch.name,
        'is_active': false,
        'created_by': widget.session.id,
      });
      if (mounted) {
        setState(() {
          future = loadAppBranchesMap();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => branchBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<int, BranchOption>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: () => setState(() {
              future = loadAppBranchesMap();
            }),
          );
        }
        final branches = snapshot.data!.values.toList();
        return Scaffold(
          body: branches.isEmpty
              ? const EmptyState(icon: Icons.store_mall_directory_rounded, text: 'لا توجد فروع مسجلة')
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: branches.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final branch = branches[i];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.store_rounded)),
                      title: Text(branch.name),
                      subtitle: Text('رقم الفرع ${branch.number}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: branchBusy ? null : (value) {
                          if (value == 'edit') openBranchDialog(branch);
                          if (value == 'delete') deleteBranch(branch);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('تعديل')),
                          PopupMenuItem(value: 'delete', child: Text('حذف')),
                        ],
                      ),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: branchBusy ? null : () => openBranchDialog(),
            icon: branchBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_business_rounded),
            label: Text(branchBusy ? 'جاري الحفظ' : 'فرع'),
          ),
        );
      },
    );
  }
}

class BranchDialog extends StatefulWidget {
  const BranchDialog({super.key, this.branch});

  final BranchOption? branch;

  @override
  State<BranchDialog> createState() => _BranchDialogState();
}

class _BranchDialogState extends State<BranchDialog> {
  final number = TextEditingController();
  final name = TextEditingController();

  @override
  void initState() {
    super.initState();
    final branch = widget.branch;
    if (branch != null) {
      number.text = '${branch.number}';
      name.text = branch.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.branch == null ? 'إضافة فرع' : 'تعديل فرع'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: number,
            enabled: widget.branch == null,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'رقم الفرع'),
          ),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'اسم الفرع')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () {
            final branchNumber = int.tryParse(number.text.trim());
            if (branchNumber == null || name.text.trim().isEmpty) return;
            Navigator.pop(context, {'sto_num': branchNumber, 'name': name.text.trim()});
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

class NotificationDiagnosticsPage extends StatefulWidget {
  const NotificationDiagnosticsPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<NotificationDiagnosticsPage> createState() => _NotificationDiagnosticsPageState();
}

class _NotificationDiagnosticsPageState extends State<NotificationDiagnosticsPage> {
  late Future<NotificationDiagnosticsData> future;
  bool sending = false;
  bool registering = false;

  @override
  void initState() {
    super.initState();
    future = loadDiagnostics();
  }

  Future<NotificationDiagnosticsData> loadDiagnostics() async {
    final tokens = await supabase
        .from('ansar_device_tokens')
        .select('id, employee_id, platform, is_active, last_seen_at, created_at')
        .order('last_seen_at', ascending: false)
        .limit(50);
    final queue = await supabase
        .from('ansar_notification_queue')
        .select('id, title, body, status, error_message, created_at, sent_at')
        .order('created_at', ascending: false)
        .limit(30);
    return NotificationDiagnosticsData(
      tokens: tokens.cast<Map<String, dynamic>>(),
      queue: queue.cast<Map<String, dynamic>>(),
    );
  }

  Future<void> runSenderNow() async {
    setState(() => sending = true);
    await kickNotificationSender();
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        sending = false;
        future = loadDiagnostics();
      });
    }
  }

  Future<void> registerThisDevice() async {
    setState(() => registering = true);
    await registerDeviceForNotifications(widget.session);
    if (mounted) {
      setState(() {
        registering = false;
        future = loadDiagnostics();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NotificationDiagnosticsData>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: () => setState(() {
              future = loadDiagnostics();
            }),
          );
        }

        final data = snapshot.data!;
        final activeTokens = data.tokens.where((row) => row['is_active'] != false).length;
        final pending = data.queue.where((row) => row['status'] == 'pending').length;
        final failed = data.queue.where((row) => row['status'] == 'failed').length;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('الأجهزة النشطة: $activeTokens')),
                Chip(label: Text('قيد الإرسال: $pending')),
                Chip(label: Text('فشل: $failed')),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: sending ? null : runSenderNow,
              icon: sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              label: const Text('تشغيل مرسل الإشعارات الآن'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: registering ? null : registerThisDevice,
              icon: registering
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.app_registration_rounded),
              label: const Text('تسجيل هذا الجهاز للإشعارات'),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: Icon(
                  lastNotificationRegistrationError == null ? Icons.check_circle_rounded : Icons.error_rounded,
                  color: lastNotificationRegistrationError == null ? Colors.green : Colors.red,
                ),
                title: const Text('حالة تسجيل هذا الجهاز'),
                subtitle: Text(
                  [
                    lastNotificationRegistrationError ??
                        (lastNotificationTokenPreview == null
                            ? 'لم يتم الحصول على رمز الجهاز بعد'
                            : 'مسجل: $lastNotificationTokenPreview'),
                    if (lastNotificationRegistrationAt != null)
                      'آخر محاولة: ${formatDateTime(lastNotificationRegistrationAt!)}',
                  ].join('\n'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'ملاحظة: التطبيق يحاول تسجيل أجهزة المستخدمين تلقائياً بعد تسجيل الدخول وأثناء فتح التطبيق.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            Text('آخر الأجهزة', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (data.tokens.isEmpty)
              const EmptyState(icon: Icons.phone_android_rounded, text: 'لا توجد أجهزة مسجلة بعد')
            else
              ...data.tokens.take(8).map(
                    (row) => ListTile(
                      leading: const Icon(Icons.phone_android_rounded),
                      title: Text(row['platform'] as String? ?? 'android'),
                      subtitle: Text(row['last_seen_at'] as String? ?? row['created_at'] as String? ?? '-'),
                      trailing: Icon(
                        row['is_active'] != false ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        color: row['is_active'] != false ? Colors.green : Colors.red,
                      ),
                    ),
                  ),
            const SizedBox(height: 16),
            Text('آخر الإشعارات', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (data.queue.isEmpty)
              const EmptyState(icon: Icons.notifications_none_rounded, text: 'لا توجد إشعارات في الطابور')
            else
              ...data.queue.map(
                (row) {
                  final status = row['status'] as String? ?? 'pending';
                  final color = status == 'sent'
                      ? Colors.green
                      : status == 'failed'
                          ? Colors.red
                          : accentColor;
                  return Card(
                    child: ListTile(
                      leading: Icon(Icons.notifications_rounded, color: color),
                      title: Text(row['title'] as String? ?? '-'),
                      subtitle: Text(
                        [
                          row['body'] as String? ?? '',
                          if (row['error_message'] != null) 'الخطأ: ${row['error_message']}',
                        ].where((value) => value.isNotEmpty).join('\n'),
                      ),
                      trailing: Text(status),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

class NotificationDiagnosticsData {
  NotificationDiagnosticsData({required this.tokens, required this.queue});

  final List<Map<String, dynamic>> tokens;
  final List<Map<String, dynamic>> queue;
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.session, required this.onSessionChanged});

  final EmployeeSession session;
  final ValueChanged<EmployeeSession> onSessionChanged;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController name;
  late final TextEditingController username;
  late final TextEditingController phone;
  late final TextEditingController email;
  late final TextEditingController jobTitle;
  bool saving = false;
  bool registeringNotifications = false;
  String? message;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.session.name);
    username = TextEditingController(text: widget.session.username);
    phone = TextEditingController(text: widget.session.phone ?? '');
    email = TextEditingController(text: widget.session.email ?? '');
    jobTitle = TextEditingController(text: widget.session.jobTitle ?? '');
  }

  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.data != widget.session.data) {
      name.text = widget.session.name;
      username.text = widget.session.username;
      phone.text = widget.session.phone ?? '';
      email.text = widget.session.email ?? '';
      jobTitle.text = widget.session.jobTitle ?? '';
    }
  }

  Future<void> saveProfile({String? avatarUrl, String? avatarPath}) async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      final update = {
        'display_name': name.text.trim(),
        'full_name': name.text.trim(),
        'username': username.text.trim(),
        'phone': emptyToNull(phone.text),
        'email': emptyToNull(email.text),
        'job_title': emptyToNull(jobTitle.text),
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        if (avatarPath != null) 'avatar_path': avatarPath,
      };
      final rows = await supabase
          .from('ansar_employees')
          .update(update)
          .eq('id', widget.session.id)
          .select();
      if (rows.isNotEmpty) widget.onSessionChanged(EmployeeSession(rows.first));
      if (mounted) showSnack(context, 'تم حفظ بياناتك');
    } catch (e) {
      setState(() => message = cleanError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 900,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      saving = true;
      message = null;
    });
    try {
      final extension = picked.path.split('.').last.toLowerCase();
      final path = '${widget.session.id}/${DateTime.now().millisecondsSinceEpoch}.$extension';
      await supabase.storage.from('ansar-avatars').upload(
            path,
            File(picked.path),
            fileOptions: const FileOptions(upsert: true),
          );
      final publicUrl = supabase.storage.from('ansar-avatars').getPublicUrl(path);
      await saveProfile(avatarUrl: publicUrl, avatarPath: path);
    } catch (e) {
      setState(() => message = 'تعذر رفع الصورة. تأكد من تفعيل تخزين الصور ثم حاول مجددا.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> enableNotifications() async {
    setState(() {
      registeringNotifications = true;
      message = null;
    });
    await registerDeviceForNotifications(widget.session);
    if (!mounted) return;
    setState(() {
      registeringNotifications = false;
      message = lastNotificationRegistrationError ??
          (lastNotificationTokenPreview == null ? 'لم يتم تسجيل الجهاز بعد' : 'تم تفعيل الإشعارات لهذا الجهاز');
    });
  }

  Future<void> resetNotifications() async {
    setState(() {
      registeringNotifications = true;
      message = null;
    });
    await resetAndRegisterDeviceForNotifications(widget.session);
    if (!mounted) return;
    setState(() {
      registeringNotifications = false;
      message = lastNotificationRegistrationError ??
          (lastNotificationTokenPreview == null ? 'لم يتم تسجيل الجهاز بعد' : 'تمت إعادة ضبط الإشعارات لهذا الجهاز');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: pagePadding,
      children: [
        const PageHeading(
          title: 'الملف الشخصي',
          subtitle: 'صورتك وبيانات التواصل والهوية الوظيفية',
          icon: Icons.person_outline_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    EmployeeAvatar(name: widget.session.name, imageUrl: widget.session.avatarUrl, radius: 42),
                    Positioned(
                      left: -3,
                      bottom: -3,
                      child: Container(
                        decoration: BoxDecoration(
                          color: brandColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: panelSurface, width: 2),
                        ),
                        child: IconButton(
                          tooltip: 'تغيير الصورة',
                          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                          padding: EdgeInsets.zero,
                          onPressed: saving ? null : pickAvatar,
                          icon: const Icon(Icons.photo_camera_rounded, color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.session.name, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(roleLabel(widget.session.role), style: const TextStyle(color: mutedInk)),
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          const StatusDot(color: successColor),
                          const SizedBox(width: 6),
                          Text('@${widget.session.username}', style: const TextStyle(color: brandColor)),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'تغيير الصورة',
                  onPressed: saving ? null : pickAvatar,
                  icon: const Icon(Icons.photo_camera_rounded),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Card(
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(color: successSurface, shape: BoxShape.circle),
              child: const Icon(Icons.notifications_active_outlined, color: brandColor),
            ),
            title: const Text('الإشعارات تعمل تلقائياً', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: const Text('يُسجّل هذا الجهاز تلقائياً عند فتح التطبيق', style: TextStyle(color: mutedInk)),
            trailing: IconButton(
              tooltip: 'إصلاح تسجيل الإشعارات',
              onPressed: registeringNotifications ? null : resetNotifications,
              icon: registeringNotifications
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const SectionHeader(title: 'البيانات الأساسية'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'الاسم', prefixIcon: Icon(Icons.badge_outlined)),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: username,
                  decoration: const InputDecoration(
                    labelText: 'اسم المستخدم',
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: jobTitle,
                  decoration: const InputDecoration(
                    labelText: 'المسمى الوظيفي',
                    prefixIcon: Icon(Icons.work_outline_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'الهاتف', prefixIcon: Icon(Icons.phone_outlined)),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'البريد', prefixIcon: Icon(Icons.email_outlined)),
                ),
              ],
            ),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: message!.contains('تم') ? successSurface : dangerColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(message!, textAlign: TextAlign.center),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: saving ? null : () => saveProfile(),
          icon: saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_rounded),
          label: const Text('حفظ التعديلات'),
        ),
      ],
    );
  }
}

class TransfersPage extends StatefulWidget {
  const TransfersPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  late Future<TransferData> future;
  TransferData? latestTransfers;
  RealtimeChannel? transferChannel;
  Timer? transferTimer;
  String statusFilter = 'active';
  int? fromBranchFilter;
  int? toBranchFilter;
  bool transferBusy = false;

  @override
  void initState() {
    super.initState();
    future = loadAndRememberTransfers();
    transferChannel = supabase.channel('transfers-live')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_transfer_orders',
        callback: (_) => refreshTransfers(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_transfer_order_items',
        callback: (_) => refreshTransfers(),
      ).subscribe();
    transferTimer = Timer.periodic(const Duration(seconds: 30), (_) => refreshTransfers());
    unawaited(warmProductSearchCache());
  }

  @override
  void dispose() {
    transferTimer?.cancel();
    if (transferChannel != null) supabase.removeChannel(transferChannel!);
    super.dispose();
  }

  void refreshTransfers() {
    if (!mounted) return;
    setState(() {
      future = loadAndRememberTransfers();
    });
  }

  Future<TransferData> loadAndRememberTransfers() async {
    final loaded = await loadTransfers();
    latestTransfers = loaded;
    return loaded;
  }

  Future<TransferData> loadTransfers() async {
    final branches = await loadAppBranchesMap();
    final employees = await loadEmployeesForScope(widget.session, includeInactive: false);
    final employeeById = {for (final employee in employees) employee.id: employee};
    final rows = await supabase
        .from('ansar_transfer_orders')
        .select()
        .order('created_at', ascending: false)
        .limit(60);
    final visible = rows.cast<Map<String, dynamic>>().where((row) {
      if (widget.session.isAdmin) return true;
      final fromBranch = nullableIntValue(row['from_branch_num']);
      final toBranch = nullableIntValue(row['to_branch_num']);
      if (widget.session.isBranchManager) {
        return fromBranch == widget.session.branchNum || toBranch == widget.session.branchNum;
      }
      return row['requested_by'] == widget.session.id || toBranch == widget.session.branchNum;
    }).toList();
    return TransferData(branches: branches, employees: employeeById, orders: visible);
  }

  List<Map<String, dynamic>> filteredOrders(List<Map<String, dynamic>> orders) {
    return orders.where((order) {
      final status = order['status'] as String? ?? 'submitted';
      final fromBranch = nullableIntValue(order['from_branch_num']);
      final toBranch = nullableIntValue(order['to_branch_num']);
      final active = !{'completed', 'cancelled', 'rejected'}.contains(status);
      final statusMatches = statusFilter == 'all' ||
          (statusFilter == 'active' ? active : status == statusFilter);
      final fromMatches = fromBranchFilter == null || fromBranch == fromBranchFilter;
      final toMatches = toBranchFilter == null || toBranch == toBranchFilter;
      return statusMatches && fromMatches && toMatches;
    }).toList();
  }

  Future<void> createOrder(TransferData data) async {
    if (data.branches.length < 2) {
      showSnack(context, 'أضف فرعين على الأقل قبل إنشاء مناقلة');
      return;
    }
    final result = await Navigator.of(context).push<CreateTransferResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: TransferDialog(
            session: widget.session,
            branches: data.branches,
          ),
        ),
      ),
    );
    if (result == null) return;
    setState(() => transferBusy = true);
    try {
      final inserted = await supabase
          .from('ansar_transfer_orders')
          .insert({
            'from_branch_num': widget.session.branchNum,
            'to_branch_num': result.toBranch,
            'requested_by': widget.session.id,
            'status': 'submitted',
            'requester_note': emptyToNull(result.note),
            'submitted_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('id')
          .single();
      await supabase.from('ansar_transfer_order_items').insert(
            result.items
                .map((item) => {
                      'order_id': inserted['id'],
                      'mat_num': item.matNum,
                      'requested_quantity': item.quantity,
                      'note': emptyToNull(item.note),
                    })
                .toList(),
          );
      await supabase.from('ansar_order_events').insert({
        'order_id': inserted['id'],
        'employee_id': widget.session.id,
        'event_type': 'created',
        'new_status': 'submitted',
        'note': 'تم إنشاء الطلب من التطبيق',
      });
      unawaited(enqueueNotification(
        title: 'مناقلة جديدة',
        body:
            'طلب مناقلة من ${branchLabel(data.branches, widget.session.branchNum)} إلى ${branchLabel(data.branches, result.toBranch)}',
        data: {'type': 'transfer_created', 'order_id': inserted['id'], 'sender_id': widget.session.id},
      ));
      if (mounted) {
        setState(() {
          future = loadAndRememberTransfers();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => transferBusy = false);
    }
  }

  Future<void> updateOrderStatus(Map<String, dynamic> order) async {
    final toBranch = nullableIntValue(order['to_branch_num']);
    if (!widget.session.isAdmin && toBranch != widget.session.branchNum) {
      showSnack(context, 'تعديل الحالة متاح فقط لموظفي الفرع المطلوب منه المناقلة');
      return;
    }
    final status = await showDialog<String>(
      context: context,
      builder: (_) => StatusDialog(current: order['status'] as String? ?? 'submitted'),
    );
    if (status == null) return;
    setState(() => transferBusy = true);
    try {
      await supabase.from('ansar_transfer_orders').update({
        'status': status,
        'handled_by': widget.session.id,
        if (status == 'approved') 'approved_at': DateTime.now().toUtc().toIso8601String(),
        if (status == 'completed') 'completed_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', order['id']);
      await supabase.from('ansar_order_events').insert({
        'order_id': order['id'],
        'employee_id': widget.session.id,
        'event_type': 'status_changed',
        'old_status': order['status'],
        'new_status': status,
      });
      unawaited(enqueueNotification(
        title: 'تحديث مناقلة',
        body: 'تم تحديث حالة المناقلة رقم ${order['order_no'] ?? '-'} إلى ${statusLabel(status)}',
        data: {'type': 'transfer_updated', 'order_id': order['id'], 'status': status, 'sender_id': widget.session.id},
      ));
      if (mounted) {
        setState(() {
          future = loadAndRememberTransfers();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => transferBusy = false);
    }
  }

  Future<void> openOrderDetails(Map<String, dynamic> order, TransferData data) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: TransferDetailsPage(
            session: widget.session,
            order: order,
            branches: data.branches,
          ),
        ),
      ),
    );
    if (mounted) {
      setState(() {
        future = loadAndRememberTransfers();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TransferData>(
      future: future,
      initialData: latestTransfers,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: refreshTransfers,
          );
        }
        if (!snapshot.hasData) {
          return ErrorState(message: 'تعذر تحميل المناقلات الآن', onRetry: refreshTransfers);
        }
        final data = snapshot.data!;
        final visibleOrders = filteredOrders(data.orders);
        return Scaffold(
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: PageHeading(
                  title: 'المناقلات',
                  subtitle: '${visibleOrders.length} طلب ضمن العرض الحالي',
                  icon: Icons.swap_horiz_rounded,
                ),
              ),
              _TransferFilters(
                branches: data.branches,
                orders: data.orders,
                statusFilter: statusFilter,
                fromBranchFilter: fromBranchFilter,
                toBranchFilter: toBranchFilter,
                onStatusChanged: (value) => setState(() => statusFilter = value),
                onFromChanged: (value) => setState(() => fromBranchFilter = value),
                onToChanged: (value) => setState(() => toBranchFilter = value),
              ),
              Expanded(
                child: visibleOrders.isEmpty
                    ? const EmptyState(
                        icon: Icons.sync_alt_rounded,
                        text: 'لا توجد مناقلات ضمن هذا العرض',
                      )
                    : ListView.separated(
                        key: const PageStorageKey('transfers-list'),
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 96),
                        itemCount: visibleOrders.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final order = visibleOrders[i];
                    final fromBranch = intValue(order['from_branch_num']);
                    final toBranch = intValue(order['to_branch_num']);
                    final requester = data.employees[order['requested_by']];
                    final canHandle = widget.session.isAdmin || toBranch == widget.session.branchNum;
                    final status = order['status'] as String? ?? 'submitted';
                    return Card(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => openOrderDetails(order, data),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: transferStatusColor(status).withValues(alpha: 0.12),
                                    child: Icon(transferStatusIcon(status), color: transferStatusColor(status)),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'طلب رقم ${order['order_no'] ?? '-'}',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                  ),
                                  StatusPill(
                                    label: statusLabel(status),
                                    color: transferStatusColor(status),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  InfoChip(icon: Icons.call_made_rounded, label: branchLabel(data.branches, fromBranch)),
                                  InfoChip(icon: Icons.call_received_rounded, label: branchLabel(data.branches, toBranch)),
                                  InfoChip(icon: Icons.person_rounded, label: requester?.name ?? 'موظف'),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: () => openOrderDetails(order, data),
                                    icon: const Icon(Icons.visibility_rounded),
                                    label: const Text('التفاصيل'),
                                  ),
                                  const Spacer(),
                                  if (canHandle)
                                    IconButton.filledTonal(
                                      tooltip: 'تحديث الحالة',
                                      onPressed: transferBusy ? null : () => updateOrderStatus(order),
                                      icon: transferBusy
                                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                          : const Icon(Icons.edit_note_rounded),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: transferBusy ? null : () => createOrder(data),
            icon: transferBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_rounded),
            label: Text(transferBusy ? 'جاري الحفظ' : 'مناقلة'),
          ),
        );
      },
    );
  }
}

class _TransferFilters extends StatelessWidget {
  const _TransferFilters({
    required this.branches,
    required this.orders,
    required this.statusFilter,
    required this.fromBranchFilter,
    required this.toBranchFilter,
    required this.onStatusChanged,
    required this.onFromChanged,
    required this.onToChanged,
  });

  final Map<int, BranchOption> branches;
  final List<Map<String, dynamic>> orders;
  final String statusFilter;
  final int? fromBranchFilter;
  final int? toBranchFilter;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<int?> onFromChanged;
  final ValueChanged<int?> onToChanged;

  int statusCount(String filter) {
    return orders.where((order) {
      final status = order['status'] as String? ?? 'submitted';
      final active = !{'completed', 'cancelled', 'rejected'}.contains(status);
      if (filter == 'all') return true;
      if (filter == 'active') return active;
      return status == filter;
    }).length;
  }

  @override
  Widget build(BuildContext context) {
    final safeFromFilter = fromBranchFilter != null && branches.containsKey(fromBranchFilter) ? fromBranchFilter : null;
    final safeToFilter = toBranchFilter != null && branches.containsKey(toBranchFilter) ? toBranchFilter : null;
    final branchItems = [
      const DropdownMenuItem<int?>(value: null, child: Text('كل الفروع')),
      ...branches.values.map((branch) => DropdownMenuItem<int?>(
            value: branch.number,
            child: Text(branch.name),
          )),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: transferStatusTabs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final value = transferStatusTabs[index];
                final selected = value == statusFilter;
                final color = value == 'all' || value == 'active' ? brandColor : transferStatusColor(value);
                return ChoiceChip(
                  selected: selected,
                  avatar: Icon(
                    value == 'all' ? Icons.all_inbox_rounded : transferStatusIcon(value),
                    size: 18,
                    color: selected ? Colors.white : color,
                  ),
                  label: Text('${transferTabLabel(value)} ${statusCount(value)}'),
                  selectedColor: color,
                  labelStyle: TextStyle(color: selected ? Colors.white : inkColor),
                  onSelected: (_) => onStatusChanged(value),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.tune_rounded, color: brandColor),
              title: const Text('تصفية حسب الفروع', style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                safeFromFilter == null && safeToFilter == null
                    ? 'كل الفروع'
                    : 'تم تطبيق تصفية مخصصة',
                style: const TextStyle(color: mutedInk, fontSize: 12),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              children: [
                DropdownButtonFormField<int?>(
                  key: ValueKey('from-${safeFromFilter ?? 'all'}'),
                  initialValue: safeFromFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'من فرع',
                    prefixIcon: Icon(Icons.call_made_rounded),
                  ),
                  items: branchItems,
                  onChanged: onFromChanged,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  key: ValueKey('to-${safeToFilter ?? 'all'}'),
                  initialValue: safeToFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'إلى فرع',
                    prefixIcon: Icon(Icons.call_received_rounded),
                  ),
                  items: branchItems,
                  onChanged: onToChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TransferDetailsPage extends StatefulWidget {
  const TransferDetailsPage({
    super.key,
    required this.session,
    required this.order,
    required this.branches,
  });

  final EmployeeSession session;
  final Map<String, dynamic> order;
  final Map<int, BranchOption> branches;

  @override
  State<TransferDetailsPage> createState() => _TransferDetailsPageState();
}

class _TransferDetailsPageState extends State<TransferDetailsPage> {
  late Future<TransferDetailsData> future;
  TransferDetailsData? latestDetails;
  RealtimeChannel? detailsChannel;
  Timer? detailsTimer;
  bool sharingPdf = false;
  bool statusBusy = false;
  String? itemBusyId;

  bool get canHandle {
    final toBranch = nullableIntValue(widget.order['to_branch_num']);
    return widget.session.isAdmin || toBranch == widget.session.branchNum;
  }

  @override
  void initState() {
    super.initState();
    future = loadAndRememberItems();
    detailsChannel = supabase.channel('transfer-details-${widget.order['id']}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_transfer_orders',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: widget.order['id'],
        ),
        callback: (payload) {
          final updated = payload.newRecord;
          if (updated.isNotEmpty) widget.order.addAll(updated);
          refreshDetails();
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_transfer_order_items',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'order_id',
          value: widget.order['id'],
        ),
        callback: (_) => refreshDetails(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_order_events',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'order_id',
          value: widget.order['id'],
        ),
        callback: (_) => refreshDetails(),
      ).subscribe();
    detailsTimer = Timer.periodic(const Duration(seconds: 30), (_) => refreshDetails());
  }

  @override
  void dispose() {
    detailsTimer?.cancel();
    if (detailsChannel != null) supabase.removeChannel(detailsChannel!);
    super.dispose();
  }

  void refreshDetails() {
    if (!mounted) return;
    setState(() {
      future = loadAndRememberItems();
    });
  }

  Future<TransferDetailsData> loadAndRememberItems() async {
    final loaded = await loadItems();
    latestDetails = loaded;
    return loaded;
  }

  Future<TransferDetailsData> loadItems() async {
    final items = await supabase
        .from('ansar_transfer_order_items')
        .select()
        .eq('order_id', widget.order['id'])
        .order('created_at', ascending: true);
    final result = items.cast<Map<String, dynamic>>();
    final matNums = result.map((row) => nullableIntValue(row['mat_num'])).whereType<int>().toList();
    final products = matNums.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase
            .from('products')
            .select('mat_num, name, quantity')
            .inFilter('mat_num', matNums);
    final productByMat = <int, Map<String, dynamic>>{};
    for (final row in products.cast<Map<String, dynamic>>()) {
      final matNum = nullableIntValue(row['mat_num']);
      if (matNum != null) productByMat[matNum] = row;
    }
    final enrichedItems = result
        .map((row) => {
              ...row,
              'product': productByMat[nullableIntValue(row['mat_num'])],
            })
        .toList();
    final eventsRows = await supabase
        .from('ansar_order_events')
        .select()
        .eq('order_id', widget.order['id'])
        .order('created_at', ascending: false);
    final events = eventsRows.cast<Map<String, dynamic>>();
    final employeesRows = await supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url');
    final employees = {
      for (final row in employeesRows.cast<Map<String, dynamic>>())
        row['id'] as String: EmployeeLite.fromRow(row),
    };
    return TransferDetailsData(items: enrichedItems, events: events, employees: employees);
  }

  Future<void> updateItem(Map<String, dynamic> item, String status) async {
    if (!canHandle) return;
    final requested = doubleValue(item['requested_quantity']);
    var approved = status == 'unavailable' ? 0.0 : requested;
    if (status == 'partially_available') {
      final controller = TextEditingController(text: requested.toStringAsFixed(0));
      final value = await showDialog<double>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('الكمية المتوفرة'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'أدخل الكمية المتوفرة'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(context, double.tryParse(controller.text.trim()) ?? 0),
              child: const Text('حفظ'),
            ),
          ],
        ),
      );
      if (value == null) return;
      approved = value.clamp(0, requested).toDouble();
    }
    setState(() => itemBusyId = '${item['id']}');
    try {
      await supabase.from('ansar_transfer_order_items').update({
        'item_status': status,
        'approved_quantity': approved,
      }).eq('id', item['id']);
      await supabase.from('ansar_order_events').insert({
        'order_id': widget.order['id'],
        'employee_id': widget.session.id,
        'event_type': 'item_changed',
        'old_status': item['item_status'],
        'new_status': status,
        'note': 'بند ${(item['product'] as Map<String, dynamic>?)?['name'] ?? item['mat_num']} - الكمية المتوفرة $approved',
      });
      unawaited(enqueueNotification(
        title: 'تحديث بند مناقلة',
        body: 'تم تحديث بند في طلب المناقلة رقم ${widget.order['order_no'] ?? '-'} إلى ${itemStatusLabel(status)}',
        data: {'type': 'transfer_item_updated', 'order_id': widget.order['id'], 'sender_id': widget.session.id},
      ));
      item['item_status'] = status;
      item['approved_quantity'] = approved;
      if (mounted) {
        setState(() {
          future = loadAndRememberItems();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => itemBusyId = null);
    }
  }

  Future<void> changeStatus() async {
    if (!canHandle || statusBusy) return;
    final status = await showDialog<String>(
      context: context,
      builder: (_) => StatusDialog(current: widget.order['status'] as String? ?? 'submitted'),
    );
    if (status == null) return;
    final oldStatus = widget.order['status'];
    setState(() => statusBusy = true);
    try {
      await supabase.from('ansar_transfer_orders').update({
        'status': status,
        'handled_by': widget.session.id,
        if (status == 'approved') 'approved_at': DateTime.now().toUtc().toIso8601String(),
        if (status == 'completed') 'completed_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.order['id']);
      await supabase.from('ansar_order_events').insert({
        'order_id': widget.order['id'],
        'employee_id': widget.session.id,
        'event_type': 'status_changed',
        'old_status': oldStatus,
        'new_status': status,
      });
      unawaited(enqueueNotification(
        title: 'تحديث مناقلة',
        body: 'تم تحديث حالة المناقلة رقم ${widget.order['order_no'] ?? '-'} إلى ${statusLabel(status)}',
        data: {'type': 'transfer_updated', 'order_id': widget.order['id'], 'status': status, 'sender_id': widget.session.id},
      ));
      widget.order['status'] = status;
      refreshDetails();
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => statusBusy = false);
    }
  }

  Future<void> sharePdf(TransferDetailsData data) async {
    setState(() => sharingPdf = true);
    try {
      final bytes = await buildTransferPdf(data);
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'ansar-transfer-${widget.order['order_no'] ?? widget.order['id']}.pdf',
      );
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => sharingPdf = false);
    }
  }

  Future<Uint8List> buildTransferPdf(TransferDetailsData data) async {
    final fromBranch = intValue(widget.order['from_branch_num']);
    final toBranch = intValue(widget.order['to_branch_num']);
    final fontBytes = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
    final logoBytes = await rootBundle.load('assets/logo.png');
    final font = pw.Font.ttf(fontBytes);
    final logo = pw.MemoryImage(
      logoBytes.buffer.asUint8List(logoBytes.offsetInBytes, logoBytes.lengthInBytes),
    );
    final theme = pw.ThemeData.withFont(base: font, bold: font);
    final document = pw.Document(theme: theme);
    final fromName = branchLabel(widget.branches, fromBranch);
    final toName = branchLabel(widget.branches, toBranch);
    final headers = ['#', 'الكتاب', 'الرقم', 'المطلوب', 'المتوفر', 'الحالة', 'الملاحظة'];
    final rows = data.items.asMap().entries.map((entry) {
      final item = entry.value;
      final product = item['product'] as Map<String, dynamic>?;
      final requested = formatMoneyValue(item['requested_quantity']);
      final approved = item['approved_quantity'] == null ? '-' : formatMoneyValue(item['approved_quantity']);
      final status = itemStatusLabel(item['item_status'] as String? ?? 'requested');
      return [
        '${entry.key + 1}',
        product?['name']?.toString() ?? 'مادة ${item['mat_num']}',
        '${item['mat_num'] ?? '-'}',
        requested,
        approved,
        status,
        item['note']?.toString() ?? '',
      ];
    }).toList();
    final eventRows = data.events.map((event) {
      final employee = data.employees['${event['employee_id']}'];
      return [
        eventLabel(event),
        employee?.name ?? 'موظف',
        formatEventTime(event['created_at']),
      ];
    }).toList();
    document.addPage(
      pw.MultiPage(
        textDirection: pw.TextDirection.rtl,
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerLeft,
          child: pw.Text(
            'صفحة ${context.pageNumber} من ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.Row(
            children: [
              pw.Container(
                width: 52,
                height: 52,
                padding: const pw.EdgeInsets.all(4),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Image(logo, fit: pw.BoxFit.contain),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('فريق الأنصار', style: const pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
                    pw.Text(
                      'طلب مناقلة من $fromName إلى $toName',
                      style: const pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xff087568)),
                    ),
                  ],
                ),
              ),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: pw.BoxDecoration(
                  color: const PdfColor.fromInt(0xffe7f4f1),
                  borderRadius: pw.BorderRadius.circular(5),
                ),
                child: pw.Text(
                  statusLabel(widget.order['status'] as String? ?? 'submitted'),
                  style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xff087568)),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Wrap(
              spacing: 26,
              runSpacing: 6,
              children: [
                pw.Text('رقم الطلب: ${widget.order['order_no'] ?? '-'}'),
                pw.Text('تاريخ التقرير: ${formatDateTime(DateTime.now())}'),
                pw.Text('عدد البنود: ${data.items.length}'),
                if (widget.order['requester_note'] != null)
                  pw.Text('ملاحظة الطلب: ${widget.order['requester_note']}'),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Text('بنود المناقلة', style: const pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: rows,
            headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff087568)),
            oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xfff4f8f7)),
            cellStyle: const pw.TextStyle(fontSize: 10),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(color: PdfColors.grey300),
            columnWidths: const {
              0: pw.FixedColumnWidth(24),
              1: pw.FlexColumnWidth(3.2),
              2: pw.FlexColumnWidth(1.1),
              3: pw.FlexColumnWidth(1.1),
              4: pw.FlexColumnWidth(1.1),
              5: pw.FlexColumnWidth(1.5),
              6: pw.FlexColumnWidth(2.2),
            },
          ),
          if (data.events.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text('سجل المعالجة', style: const pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['التحديث', 'نفذه', 'الوقت'],
              data: eventRows,
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff344f49)),
              oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xfff4f8f7)),
              cellStyle: const pw.TextStyle(fontSize: 10),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(color: PdfColors.grey300),
              columnWidths: const {
                0: pw.FlexColumnWidth(4),
                1: pw.FlexColumnWidth(2),
                2: pw.FlexColumnWidth(1.5),
              },
            ),
          ],
        ],
      ),
    );
    return document.save();
  }

  @override
  Widget build(BuildContext context) {
    final fromBranch = intValue(widget.order['from_branch_num']);
    final toBranch = intValue(widget.order['to_branch_num']);
    return Scaffold(
      appBar: AppBar(
        title: Text('مناقلة ${widget.order['order_no'] ?? ''}'),
        actions: [
          if (canHandle)
            IconButton(
              tooltip: 'تغيير الحالة',
              onPressed: statusBusy ? null : changeStatus,
              icon: statusBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.edit_note_rounded),
            ),
        ],
      ),
      body: FutureBuilder<TransferDetailsData>(
        future: future,
        initialData: latestDetails,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return ErrorState(
              message: cleanError(snapshot.error),
              onRetry: () => setState(() {
                future = loadAndRememberItems();
              }),
            );
          }
          if (!snapshot.hasData) {
            return ErrorState(
              message: 'تعذر تحميل تفاصيل المناقلة الآن',
              onRetry: () => setState(() {
                future = loadAndRememberItems();
              }),
            );
          }
          final details = snapshot.data!;
          final items = details.items;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          InfoChip(icon: Icons.call_made_rounded, label: branchLabel(widget.branches, fromBranch)),
                          InfoChip(icon: Icons.call_received_rounded, label: branchLabel(widget.branches, toBranch)),
                          StatusPill(
                            label: statusLabel(widget.order['status'] as String? ?? 'submitted'),
                            color: transferStatusColor(widget.order['status'] as String? ?? 'submitted'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: sharingPdf ? null : () => sharePdf(details),
                        icon: sharingPdf
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.picture_as_pdf_rounded),
                        label: const Text('مشاركة PDF'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const SectionHeader(title: 'بنود الطلب'),
              if (items.isEmpty)
                const EmptyState(icon: Icons.inventory_2_outlined, text: 'لا توجد بنود')
              else
                ...items.map((item) {
                  final product = item['product'] as Map<String, dynamic>?;
                  final status = item['item_status'] as String? ?? 'requested';
                  final busy = itemBusyId == '${item['id']}';
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            product?['name']?.toString() ?? 'مادة ${item['mat_num']}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              Chip(label: Text('المطلوب ${item['requested_quantity']}')),
                              Chip(label: Text('المتوفر ${item['approved_quantity'] ?? '-'}')),
                              Chip(
                                avatar: Icon(transferStatusIcon(status), size: 16),
                                label: Text(itemStatusLabel(status)),
                              ),
                            ],
                          ),
                          if (item['note'] != null) Text('ملاحظة: ${item['note']}'),
                          if (canHandle) ...[
                            const SizedBox(height: 8),
                            if (busy)
                              const LinearProgressIndicator(minHeight: 2)
                            else
                              Wrap(
                                spacing: 8,
                                children: [
                                  ActionChip(
                                    label: const Text('متوفر'),
                                    onPressed: () => updateItem(item, 'available'),
                                  ),
                                  ActionChip(
                                    label: const Text('جزئي'),
                                    onPressed: () => updateItem(item, 'partially_available'),
                                  ),
                                  ActionChip(
                                    label: const Text('غير متوفر'),
                                    onPressed: () => updateItem(item, 'unavailable'),
                                  ),
                                ],
                              ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 12),
              const SectionHeader(title: 'سجل المعالجة'),
              if (details.events.isEmpty)
                const EmptyState(icon: Icons.history_rounded, text: 'لا توجد تحديثات بعد')
              else
                ...details.events.map((event) {
                  final employee = details.employees[event['employee_id']];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: brandColor.withValues(alpha: 0.1),
                      child: const Icon(Icons.manage_history_rounded, color: brandColor),
                    ),
                    title: Text(eventLabel(event)),
                    subtitle: Text('${employee?.name ?? 'موظف'} · ${formatEventTime(event['created_at'])}'),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

class TransferData {
  TransferData({required this.branches, required this.employees, required this.orders});

  final Map<int, BranchOption> branches;
  final Map<String, EmployeeLite> employees;
  final List<Map<String, dynamic>> orders;
}

class TransferDetailsData {
  TransferDetailsData({
    required this.items,
    required this.events,
    required this.employees,
  });

  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> events;
  final Map<String, EmployeeLite> employees;
}

class CreateTransferResult {
  CreateTransferResult({required this.toBranch, required this.note, required this.items});

  final int toBranch;
  final String note;
  final List<TransferItemDraft> items;
}

class TransferItemDraft {
  TransferItemDraft({
    required this.matNum,
    required this.name,
    required this.quantity,
    required this.note,
  });

  final int matNum;
  final String name;
  final double quantity;
  final String note;
}

class TransferDialog extends StatefulWidget {
  const TransferDialog({super.key, required this.session, required this.branches});

  final EmployeeSession session;
  final Map<int, BranchOption> branches;

  @override
  State<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<TransferDialog> {
  final note = TextEditingController();
  final bookSearch = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final itemNote = TextEditingController();
  final items = <TransferItemDraft>[];
  List<Map<String, dynamic>> suggestions = [];
  Map<String, dynamic>? selectedProduct;
  bool searching = false;
  bool cacheLoading = true;
  int productsCount = 0;
  Timer? searchDebounce;
  int? toBranch;

  @override
  void initState() {
    super.initState();
    unawaited(prepareSearchCache());
  }

  @override
  void dispose() {
    searchDebounce?.cancel();
    note.dispose();
    bookSearch.dispose();
    quantity.dispose();
    itemNote.dispose();
    super.dispose();
  }

  Future<void> prepareSearchCache() async {
    try {
      await warmProductSearchCache();
      if (mounted) {
        setState(() {
          productsCount = cachedProducts?.length ?? 0;
          cacheLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => cacheLoading = false);
    }
  }

  void queueSearch(String value) {
    selectedProduct = null;
    searchDebounce?.cancel();
    searchDebounce = Timer(const Duration(milliseconds: 260), () => searchBooks(value));
  }

  Future<void> searchBooks(String value) async {
    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        suggestions = [];
        searching = false;
      });
      return;
    }
    setState(() => searching = true);
    try {
      await warmProductSearchCache();
      final found = await searchProductsLikeLegacy(query, limit: 12);
      if (mounted) {
        if (bookSearch.text.trim() != query) return;
        setState(() {
          suggestions = found;
          searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => searching = false);
    }
  }

  void selectProduct(Map<String, dynamic> product) {
    setState(() {
      selectedProduct = product;
      bookSearch.text = product['name'] as String? ?? '${product['mat_num']}';
      suggestions = [];
    });
  }

  void addItem() {
    final product = selectedProduct;
    final parsedQuantity = double.tryParse(quantity.text.trim());
    final parsedMat = nullableIntValue(product?['mat_num']);
    if (product == null || parsedMat == null || parsedQuantity == null || parsedQuantity <= 0) return;
    setState(() {
      items.add(TransferItemDraft(
        matNum: parsedMat,
        name: product['name'] as String? ?? 'كتاب $parsedMat',
        quantity: parsedQuantity,
        note: itemNote.text.trim(),
      ));
      selectedProduct = null;
      bookSearch.clear();
      quantity.text = '1';
      itemNote.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = toBranch != null && items.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('طلب مناقلة جديد'),
        actions: [
          IconButton(
            tooltip: 'إغلاق',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
        children: [
          const PageHeading(
            title: 'إنشاء طلب واضح وقابل للمتابعة',
            subtitle: 'حدد الفرع ثم أضف الكتب والكميات المطلوبة',
            icon: Icons.playlist_add_rounded,
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<int>(
                    initialValue: toBranch,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'الفرع المطلوب منه',
                      prefixIcon: Icon(Icons.storefront_rounded),
                    ),
                    items: widget.branches.values
                        .where((branch) => branch.number != widget.session.branchNum)
                        .map((branch) => DropdownMenuItem(value: branch.number, child: Text(branch.label)))
                        .toList(),
                    onChanged: (value) => setState(() => toBranch = value),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: note,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'ملاحظة الطلب',
                      prefixIcon: Icon(Icons.notes_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const SectionHeader(title: 'إضافة الكتب'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: bookSearch,
                    decoration: InputDecoration(
                      labelText: 'ابحث عن الكتاب',
                      helperText: cacheLoading
                          ? 'يتم تجهيز فهرس الكتب لأول مرة'
                          : productsCount > 0
                              ? 'جاهز للبحث السريع داخل $productsCount كتاب'
                              : null,
                      prefixIcon: const Icon(Icons.menu_book_rounded),
                      suffixIcon: searching || cacheLoading
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : const Icon(Icons.manage_search_rounded),
                    ),
                    onChanged: queueSearch,
                  ),
                  if (suggestions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 260),
                      decoration: BoxDecoration(
                        color: softSurface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: borderColor),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: suggestions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final product = suggestions[index];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.menu_book_rounded),
                            title: Text(product['name'] as String? ?? 'بدون اسم'),
                            subtitle: Text('رقم ${product['mat_num']} · كمية ${product['quantity'] ?? '-'}'),
                            onTap: () => selectProduct(product),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: quantity,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'الكمية المطلوبة',
                      prefixIcon: Icon(Icons.numbers_rounded),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: itemNote,
                    decoration: const InputDecoration(
                      labelText: 'ملاحظة البند (اختياري)',
                      prefixIcon: Icon(Icons.notes_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: addItem,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('إضافة الكتاب إلى الطلب'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SectionHeader(title: 'بنود الطلب (${items.length})'),
          if (items.isEmpty)
            const EmptyState(icon: Icons.playlist_add_rounded, text: 'أضف كتابا واحدا على الأقل')
          else
            ...items.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_outline_rounded, color: brandColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                InfoChip(icon: Icons.tag_rounded, label: 'رقم ${item.matNum}'),
                                InfoChip(icon: Icons.numbers_rounded, label: 'الكمية ${formatMoneyValue(item.quantity)}'),
                                if (item.note.isNotEmpty) InfoChip(icon: Icons.notes_rounded, label: item.note),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'حذف البند',
                        onPressed: () => setState(() => items.removeAt(index)),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: panelSurface,
            border: Border(top: BorderSide(color: borderColor)),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: canSubmit
                      ? () => Navigator.pop(
                            context,
                            CreateTransferResult(toBranch: toBranch!, note: note.text.trim(), items: items),
                          )
                      : null,
                  icon: const Icon(Icons.send_rounded),
                  label: const Text('إرسال الطلب'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StatusDialog extends StatefulWidget {
  const StatusDialog({super.key, required this.current});

  final String current;

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  late String status = widget.current;

  @override
  Widget build(BuildContext context) {
    const statuses = [
      'submitted',
      'approved',
      'partially_available',
      'preparing',
      'in_delivery',
      'completed',
      'rejected',
      'cancelled',
    ];
    return AlertDialog(
      title: const Text('تحديث حالة المناقلة'),
      content: DropdownButtonFormField<String>(
        initialValue: status,
        items: statuses
            .map((value) => DropdownMenuItem(value: value, child: Text(statusLabel(value))))
            .toList(),
        onChanged: (value) => setState(() => status = value ?? widget.current),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(context, status), child: const Text('حفظ')),
      ],
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late Future<List<Map<String, dynamic>>> future;
  bool threadBusy = false;

  @override
  void initState() {
    super.initState();
    future = loadThreads();
  }

  Future<List<Map<String, dynamic>>> loadThreads() async {
    final rows = await supabase
        .from('ansar_chat_threads')
        .select()
        .eq('is_active', true)
        .order('updated_at', ascending: false);

    final participants = await supabase
        .from('ansar_chat_participants')
        .select('thread_id')
        .eq('employee_id', widget.session.id);
    final joinedThreadIds = participants.map((row) => row['thread_id']).toSet();

    return rows.cast<Map<String, dynamic>>().where((row) {
      final type = row['thread_type'] as String? ?? 'general';
      if (type == 'general') return true;
      if (widget.session.isAdmin) return true;
      return joinedThreadIds.contains(row['id']);
    }).toList();
  }

  Future<void> openThread(Map<String, dynamic> thread) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: ChatThreadPage(session: widget.session, thread: thread),
        ),
      ),
    );
    if (mounted) {
      setState(() {
        future = loadThreads();
      });
    }
  }

  Future<void> createThread() async {
    final employees = await loadEmployeesForScope(widget.session, includeInactive: false);
    if (!mounted) return;
    final result = await showDialog<CreateThreadResult>(
      context: context,
      builder: (_) => CreateThreadDialog(session: widget.session, employees: employees),
    );
    if (result == null) return;

    setState(() => threadBusy = true);
    try {
      final inserted = await supabase
          .from('ansar_chat_threads')
          .insert({
            'title': result.title,
            'thread_type': result.employeeIds.length == 1 ? 'direct' : 'group',
            'created_by': widget.session.id,
          })
          .select('id')
          .single();
      final threadId = inserted['id'];
      final participantIds = {widget.session.id, ...result.employeeIds};
      await supabase.from('ansar_chat_participants').insert(
            participantIds
                .map((employeeId) => {
                      'thread_id': threadId,
                      'employee_id': employeeId,
                      'role': employeeId == widget.session.id ? 'admin' : 'member',
                    })
                .toList(),
          );
      if (mounted) {
        setState(() {
          future = loadThreads();
        });
      }
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => threadBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: () => setState(() {
              future = loadThreads();
            }),
          );
        }
        final threads = snapshot.data!;
        return Scaffold(
          body: ListView(
            key: const PageStorageKey('chat-list'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: [
              const PageHeading(
                title: 'الدردشة',
                subtitle: 'المحادثات العامة والخاصة ومجموعات العمل',
                icon: Icons.chat_bubble_outline_rounded,
              ),
              if (threads.isEmpty)
                const EmptyState(icon: Icons.chat_bubble_outline_rounded, text: 'لا توجد محادثات بعد')
              else
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < threads.length; i++) ...[
                        Builder(builder: (context) {
                          final thread = threads[i];
                          final general = thread['thread_type'] == 'general';
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                            leading: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: (general ? accentColor : brandColor).withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                general ? Icons.campaign_rounded : Icons.forum_outlined,
                                color: general ? accentColor : brandColor,
                              ),
                            ),
                            title: Text(
                              thread['title'] as String? ?? 'محادثة',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            subtitle: Text(
                              chatTypeLabel(thread['thread_type'] as String? ?? 'general'),
                              style: const TextStyle(color: mutedInk),
                            ),
                            trailing: const Icon(Icons.chevron_left_rounded, color: mutedInk),
                            onTap: () => openThread(thread),
                          );
                        }),
                        if (i != threads.length - 1) const Divider(indent: 72),
                      ],
                    ],
                  ),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: threadBusy ? null : createThread,
            icon: threadBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_comment_rounded),
            label: Text(threadBusy ? 'جاري الحفظ' : 'محادثة جديدة'),
          ),
        );
      },
    );
  }
}

class ChatThreadPage extends StatefulWidget {
  const ChatThreadPage({super.key, required this.session, required this.thread});

  final EmployeeSession session;
  final Map<String, dynamic> thread;

  @override
  State<ChatThreadPage> createState() => _ChatThreadPageState();
}

class _ChatThreadPageState extends State<ChatThreadPage> {
  final message = TextEditingController();
  late Future<List<Map<String, dynamic>>> future;
  List<Map<String, dynamic>>? latestMessages;
  Timer? timer;
  RealtimeChannel? channel;
  bool sendingMessage = false;

  @override
  void initState() {
    super.initState();
    future = loadAndRememberMessages();
    channel = supabase.channel('chat-thread-${widget.thread['id']}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'thread_id',
          value: widget.thread['id'],
        ),
        callback: (_) {
          if (mounted) {
            setState(() {
              future = loadAndRememberMessages();
            });
          }
        },
      ).subscribe();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          future = loadAndRememberMessages();
        });
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    if (channel != null) supabase.removeChannel(channel!);
    message.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> loadAndRememberMessages() async {
    final loaded = await loadMessages();
    latestMessages = loaded;
    return loaded;
  }

  Future<List<Map<String, dynamic>>> loadMessages() async {
    final rows = await supabase
        .from('ansar_chat_messages')
        .select()
        .eq('thread_id', widget.thread['id'])
        .isFilter('deleted_at', null)
        .order('created_at', ascending: true)
        .limit(120);
    final messages = rows.cast<Map<String, dynamic>>();
    final senderIds = messages.map((row) => row['sender_id'] as String?).whereType<String>().toSet().toList();
    final employeeRows = senderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase
            .from('ansar_employees')
            .select('id, display_name, full_name, username')
            .inFilter('id', senderIds);
    final names = {
      for (final row in employeeRows.cast<Map<String, dynamic>>())
        row['id'] as String: (row['display_name'] ?? row['full_name'] ?? row['username'] ?? 'موظف') as String,
    };
    return messages.map((row) => {...row, 'sender_name': names[row['sender_id']] ?? 'موظف'}).toList();
  }

  Future<void> sendMessage() async {
    final body = message.text.trim();
    if (body.isEmpty || sendingMessage) return;
    message.clear();
    setState(() => sendingMessage = true);
    try {
      await supabase.from('ansar_chat_messages').insert({
        'thread_id': widget.thread['id'],
        'sender_id': widget.session.id,
        'body': body,
        'message_type': 'text',
      });
      await supabase
          .from('ansar_chat_threads')
          .update({'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', widget.thread['id']);
      if (mounted) {
        setState(() {
          future = loadAndRememberMessages();
        });
      }
      unawaited(enqueueChatNotification(
        thread: widget.thread,
        sender: widget.session,
        body: body.length > 80 ? '${body.substring(0, 80)}...' : body,
      ));
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
      message.text = body;
    } finally {
      if (mounted) setState(() => sendingMessage = false);
    }
  }

  Future<void> deleteMessage(Map<String, dynamic> row) async {
    if (row['sender_id'] != widget.session.id && !widget.session.isAdmin) return;
    await supabase
        .from('ansar_chat_messages')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()}).eq('id', row['id']);
    setState(() {
      future = loadAndRememberMessages();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.thread['title'] as String? ?? 'محادثة'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: () => setState(() {
              future = loadAndRememberMessages();
            }),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: future,
              initialData: latestMessages,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError && !snapshot.hasData) {
                  return ErrorState(
                    message: cleanError(snapshot.error),
                    onRetry: () => setState(() {
                      future = loadAndRememberMessages();
                    }),
                  );
                }
                final messages = snapshot.data!;
                if (messages.isEmpty) {
                  return const EmptyState(icon: Icons.mark_chat_unread_rounded, text: 'ابدأ أول رسالة');
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final row = messages[i];
                    final mine = row['sender_id'] == widget.session.id;
                    final senderName = mine ? 'أنت' : row['sender_name'] as String? ?? 'موظف';
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: Material(
                            color: mine ? successSurface : panelSurface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: mine ? successSurface : borderColor),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onLongPress: () => deleteMessage(row),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(13, 10, 13, 9),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      senderName,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        color: mine ? brandColor : infoColor,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(row['body'] as String? ?? ''),
                                    const SizedBox(height: 6),
                                    Text(
                                      formatDateTime(DateTime.parse(row['created_at'] as String).toLocal()),
                                      style: const TextStyle(fontSize: 10, color: mutedInk),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: const BoxDecoration(
                color: panelSurface,
                border: Border(top: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: message,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'اكتب رسالة',
                        prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                      ),
                      onSubmitted: (_) => sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: sendingMessage ? null : sendMessage,
                    icon: sendingMessage
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CreateThreadResult {
  CreateThreadResult({required this.title, required this.employeeIds});

  final String title;
  final List<String> employeeIds;
}

class CreateThreadDialog extends StatefulWidget {
  const CreateThreadDialog({super.key, required this.session, required this.employees});

  final EmployeeSession session;
  final List<EmployeeLite> employees;

  @override
  State<CreateThreadDialog> createState() => _CreateThreadDialogState();
}

class _CreateThreadDialogState extends State<CreateThreadDialog> {
  final title = TextEditingController();
  final selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final employees = widget.employees.where((employee) => employee.id != widget.session.id).toList();
    return AlertDialog(
      title: const Text('محادثة جديدة'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'عنوان المحادثة')),
              const SizedBox(height: 8),
              ...employees.map(
                (employee) => CheckboxListTile(
                  value: selected.contains(employee.id),
                  title: Text(employee.name),
                  subtitle: Text(roleLabel(employee.role)),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        selected.add(employee.id);
                      } else {
                        selected.remove(employee.id);
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () {
                  final fallbackTitle = selected.length == 1 ? 'محادثة خاصة' : 'مجموعة جديدة';
                  Navigator.pop(
                    context,
                    CreateThreadResult(
                      title: title.text.trim().isEmpty ? fallbackTitle : title.text.trim(),
                      employeeIds: selected.toList(),
                    ),
                  );
                },
          child: const Text('إنشاء'),
        ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.action,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: successSurface, shape: BoxShape.circle),
            child: Icon(icon, color: brandColor, size: 23),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(color: mutedInk, fontSize: 13)),
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            action!,
          ],
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 21),
                ),
                const Spacer(),
                Text(
                  value,
                  style: TextStyle(color: color, fontSize: 23, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: mutedInk, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class MovementTile extends StatelessWidget {
  const MovementTile({super.key, required this.movement});

  final Movement movement;

  @override
  Widget build(BuildContext context) {
    final isIn = movement.type == 'دخول';
    final color = isIn ? successColor : dangerColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(
              isIn ? Icons.login_rounded : Icons.logout_rounded,
              color: color,
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${movement.employee.name} · ${movement.type}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(movement.branchName, style: const TextStyle(color: mutedInk, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatTime(movement.time),
            style: const TextStyle(color: mutedInk, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class BranchLogo extends StatelessWidget {
  const BranchLogo({super.key, required this.branchName, this.size = 44});

  final String branchName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = branchLogoAsset(branchName);
    final fallback = Icon(Icons.storefront_rounded, color: brandColor, size: size * 0.48);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: asset == null
          ? fallback
          : Image.asset(
              asset,
              fit: BoxFit.contain,
              cacheWidth: (size * 5).round(),
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}

class BranchStatusCard extends StatelessWidget {
  const BranchStatusCard({super.key, required this.branch, required this.onTap});

  final BranchStatus branch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final open = branch.isOpen;
    final count = branch.activeEmployees.length;
    final color = open ? successColor : dangerColor;
    return Card(
      margin: EdgeInsets.zero,
      color: open ? successSurface.withValues(alpha: 0.48) : panelSurface,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BranchLogo(branchName: branch.branchName, size: 42),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      branch.branchName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, height: 1.35),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  StatusDot(color: color, size: 8),
                  const SizedBox(width: 6),
                  Text(open ? 'مفتوح الآن' : 'مغلق', style: TextStyle(color: color, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                open ? (count == 1 ? 'موظف واحد داخل الفرع' : '$count موظفين داخل الفرع') : 'لا يوجد موظفون الآن',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: mutedInk, fontSize: 11),
              ),
              const SizedBox(height: 7),
              const Row(
                children: [
                  Text('تفاصيل دوام اليوم', style: TextStyle(color: brandColor, fontSize: 11, fontWeight: FontWeight.w800)),
                  Spacer(),
                  Icon(Icons.chevron_left_rounded, color: brandColor, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DailyHoursChart extends StatelessWidget {
  const DailyHoursChart({super.key, required this.values});

  final Map<String, double> values;

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final shown = entries.length > 14 ? entries.sublist(entries.length - 14) : entries;
    final maxHours = shown.fold<double>(0, (max, item) => item.value > max ? item.value : max);
    final chartMax = maxHours <= 0 ? 1.0 : maxHours * 1.18;
    final interval = chartMax <= 4 ? 1.0 : (chartMax / 4).ceilToDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.bar_chart_rounded, color: brandColor, size: 20),
                const SizedBox(width: 7),
                Text(
                  shown.length < entries.length ? 'آخر ${shown.length} يوماً من النطاق' : 'ساعات الدوام اليومية',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: chartMax,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: interval,
                    getDrawingHorizontalLine: (_) => const FlLine(color: borderColor, strokeWidth: 1),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: const Border(
                      bottom: BorderSide(color: borderColor),
                      left: BorderSide(color: borderColor),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 31,
                        interval: interval,
                        getTitlesWidget: (value, meta) => Text(
                          value.toStringAsFixed(0),
                          style: const TextStyle(color: mutedInk, fontSize: 9),
                        ),
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= shown.length) return const SizedBox.shrink();
                          if (shown.length > 8 && index.isOdd && index != shown.length - 1) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(reportDayLabel(shown[index].key), style: const TextStyle(color: mutedInk, fontSize: 9)),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < shown.length; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: shown[i].value,
                            color: i == shown.length - 1
                                ? accentColor
                                : i.isEven
                                    ? brandColor
                                    : successColor,
                            width: shown.length > 10 ? 11 : 15,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(5),
                              topRight: Radius.circular(5),
                            ),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: chartMax,
                              color: softSurface,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DurationListTile extends StatelessWidget {
  const DurationListTile({super.key, required this.item, this.rank});

  final EmployeeDuration item;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          EmployeeAvatar(name: item.employee.name, imageUrl: item.employee.avatarUrl),
          if (rank != null)
            Positioned(
              right: -5,
              top: -5,
              child: Container(
                width: 19,
                height: 19,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: rank == 1 ? accentColor : brandColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: panelSurface, width: 2),
                ),
                child: Text('$rank', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ),
      title: Text(item.employee.name, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('${item.days} أيام حضور · ${item.openLogs} مفتوح', style: const TextStyle(color: mutedInk)),
      trailing: Text(
        '${item.hours.toStringAsFixed(1)} س',
        style: const TextStyle(color: brandColor, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 9});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      child: SizedBox.square(dimension: size),
    );
  }
}

class EmployeeAvatar extends StatelessWidget {
  const EmployeeAvatar({super.key, required this.name, this.imageUrl, this.radius = 20});

  final String name;
  final String? imageUrl;
  final double radius;

  Widget initialsAvatar() {
    final trimmedName = name.trim();
    final initials = trimmedName.isEmpty ? '؟' : trimmedName.substring(0, 1);
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: successSurface, shape: BoxShape.circle),
      child: Text(
        initials,
        style: TextStyle(color: brandColor, fontWeight: FontWeight.w800, fontSize: radius * 0.85),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim() ?? '';
    if (url.isEmpty) return initialsAvatar();
    return ClipOval(
      child: Image.network(
        url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => initialsAvatar(),
        loadingBuilder: (context, child, progress) => progress == null ? child : initialsAvatar(),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: const BoxDecoration(color: Color(0xffedf2f0), shape: BoxShape.circle),
              child: Icon(icon, size: 28, color: mutedInk),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: mutedInk, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(color: dangerColor.withValues(alpha: 0.09), shape: BoxShape.circle),
              child: const Icon(Icons.error_outline_rounded, size: 30, color: dangerColor),
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: mutedInk)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<Map<int, BranchOption>> loadLegacyBranchesMap() async {
  final branches = <int, BranchOption>{};
  final legacyRows = await supabase.from('branches').select('sto_num, name').order('sto_num');
  for (final row in legacyRows) {
    final number = (row['sto_num'] as num?)?.toInt();
    if (number == null) continue;
    branches[number] = BranchOption(
      number: number,
      name: (row['name'] ?? 'فرع $number') as String,
    );
  }
  return branches;
}

Future<Map<int, BranchOption>> loadAppBranchesMap() async {
  final branches = <int, BranchOption>{};
  try {
    final appRows = await supabase
        .from('ansar_branches')
        .select('sto_num, name, is_active')
        .order('sto_num');
    for (final row in appRows) {
      final number = (row['sto_num'] as num?)?.toInt();
      if (number == null) continue;
      if (row['is_active'] == false) {
        branches.remove(number);
      } else {
        branches[number] = BranchOption(
          number: number,
          name: (row['name'] ?? 'فرع $number') as String,
        );
      }
    }
  } catch (_) {
    // ansar_branches may not exist yet while the user is setting up the database.
  }
  return branches;
}

Future<Map<int, BranchOption>> loadBranchesMap() async {
  final legacy = await loadLegacyBranchesMap();
  final app = await loadAppBranchesMap();
  return {...legacy, ...app};
}

Future<List<Map<String, dynamic>>> loadAllProductsCached() async {
  if (cachedProducts != null) return cachedProducts!;
  final running = cachedProductsFuture;
  if (running != null) return running;
  cachedProductsFuture = _loadAllProducts();
  try {
    cachedProducts = await cachedProductsFuture;
    return cachedProducts!;
  } finally {
    cachedProductsFuture = null;
  }
}

Future<List<Map<String, dynamic>>> _loadAllProducts() async {
  final all = <Map<String, dynamic>>[];
  var from = 0;
  const pageSize = 1000;
  while (true) {
    final rows = await supabase
        .from('products')
        .select()
        .range(from, from + pageSize - 1);
    final page = rows.cast<Map<String, dynamic>>();
    all.addAll(page);
    if (page.length < pageSize) break;
    from += pageSize;
  }
  final unique = <int, Map<String, dynamic>>{};
  for (final product in all) {
    final matNum = (product['mat_num'] as num?)?.toInt();
    if (matNum != null) unique.putIfAbsent(matNum, () => product);
  }
  return unique.values.toList();
}

Future<Map<int, String>> loadAllBarcodesCached() async {
  if (cachedBarcodes != null) return cachedBarcodes!;
  final running = cachedBarcodesFuture;
  if (running != null) return running;
  cachedBarcodesFuture = _loadAllBarcodes();
  try {
    cachedBarcodes = await cachedBarcodesFuture;
    return cachedBarcodes!;
  } finally {
    cachedBarcodesFuture = null;
  }
}

Future<Map<int, String>> _loadAllBarcodes() async {
  final all = <Map<String, dynamic>>[];
  var from = 0;
  const pageSize = 1000;
  while (true) {
    final rows = await supabase
        .from('product_barcodes')
        .select('mat_num, barcode')
        .range(from, from + pageSize - 1);
    final page = rows.cast<Map<String, dynamic>>();
    all.addAll(page);
    if (page.length < pageSize) break;
    from += pageSize;
  }
  final map = <int, String>{};
  for (final row in all) {
    final matNum = (row['mat_num'] as num?)?.toInt();
    final barcode = row['barcode'] as String?;
    if (matNum != null && barcode != null && barcode.isNotEmpty) {
      map[matNum] = barcode;
    }
  }
  return map;
}

Future<void> warmProductSearchCache() async {
  await Future.wait([loadAllProductsCached(), loadAllBarcodesCached()]);
}

Future<List<Map<String, dynamic>>> loadAccountsCached() async {
  if (cachedAccounts != null) return cachedAccounts!;
  final running = cachedAccountsFuture;
  if (running != null) return running;
  cachedAccountsFuture = supabase
      .from('accounts')
      .select('num, name, ras, owner')
      .order('num', ascending: true)
      .then((rows) => rows.cast<Map<String, dynamic>>());
  try {
    cachedAccounts = await cachedAccountsFuture;
    return cachedAccounts!;
  } finally {
    cachedAccountsFuture = null;
  }
}

Future<void> warmQueriesCache() async {
  await Future.wait([
    warmProductSearchCache(),
    loadAccountsCached(),
    loadLegacyBranchesMap(),
  ]);
}

Future<List<Map<String, dynamic>>> searchProductsLikeLegacy(
  String query, {
  required int limit,
}) async {
  final products = await loadAllProductsCached();
  final barcodes = await loadAllBarcodesCached();
  final normalized = normalizeSearch(query);
  final words = normalized.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  final scored = <({Map<String, dynamic> product, double score})>[];
  for (final product in products) {
    final score = productSearchScore(product, normalized, words, barcodes);
    if (score > 0) scored.add((product: product, score: score));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored.take(limit).map((item) => item.product).toList();
}

double productSearchScore(
  Map<String, dynamic> product,
  String query,
  List<String> words,
  Map<int, String> barcodes,
) {
  final matNum = (product['mat_num'] as num?)?.toInt();
  final matText = matNum?.toString() ?? '';
  final name = normalizeSearch(product['name'] as String? ?? '');
  final barcode = matNum == null ? '' : (barcodes[matNum] ?? '');
  if (query.isEmpty) return 0;
  if (matText == query) return 120;
  if (barcode == query) return 120;
  if (name == query) return 110;
  if (name.startsWith(query)) return 108;
  if (name.contains(query)) return 106;
  if (words.isNotEmpty && words.every(name.contains)) return 100;
  if (matText.contains(query)) return 90;
  if (barcode.contains(query)) return 85;
  final matchedWords = words.where(name.contains).length;
  if (matchedWords > 0) return 70 * matchedWords / words.length;
  return 0;
}

String normalizeSearch(String value) {
  return value
      .toLowerCase()
      .replaceAll('أ', 'ا')
      .replaceAll('إ', 'ا')
      .replaceAll('آ', 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .trim();
}

Future<List<EmployeeLite>> loadEmployeesForScope(
  EmployeeSession session, {
  required bool includeInactive,
}) async {
  var query = supabase
      .from('ansar_employees')
      .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url');
  if (!includeInactive) query = query.eq('is_active', true);
  if (!session.isAdmin && session.isBranchManager) {
    query = query.eq('branch_num', session.branchNum);
  } else if (!session.isAdmin) {
    query = query.eq('id', session.id);
  }
  final rows = await query.order('display_name', ascending: true);
  return rows.map(EmployeeLite.fromRow).toList();
}

List<Movement> buildMovementsFromRows(
  List<Map<String, dynamic>> rows,
  Map<String, EmployeeLite> employees,
  Map<int, BranchOption> branches,
) {
  final movements = <Movement>[];
  for (final row in rows) {
    final employeeId = row['employee_id'] as String?;
    if (employeeId == null || !employees.containsKey(employeeId)) continue;
    final employee = employees[employeeId]!;
    final branchNum = (row['branch_num'] as num?)?.toInt() ?? employee.branchNum;
    final branchName = branchLabel(branches, branchNum);
    final checkInValue = row['check_in_at'] as String?;
    final checkOutValue = row['check_out_at'] as String?;
    if (checkInValue != null) {
      movements.add(Movement(
        employee: employee,
        branchName: branchName,
        time: DateTime.parse(checkInValue).toLocal(),
        type: 'دخول',
      ));
    }
    if (checkOutValue != null) {
      movements.add(Movement(
        employee: employee,
        branchName: branchName,
        time: DateTime.parse(checkOutValue).toLocal(),
        type: 'خروج',
      ));
    }
  }
  movements.sort((a, b) => b.time.compareTo(a.time));
  return movements;
}

String branchLabel(Map<int, BranchOption> branches, int branchNum) {
  return branches[branchNum]?.name ?? 'فرع رقم $branchNum';
}

String roleLabel(String role) {
  switch (role) {
    case 'admin':
      return 'مدير عام';
    case 'branch_manager':
      return 'مدير فرع';
    default:
      return 'موظف';
  }
}

String statusLabel(String status) {
  switch (status) {
    case 'draft':
      return 'مسودة';
    case 'submitted':
      return 'مرسل';
    case 'approved':
      return 'موافق عليه';
    case 'partially_available':
      return 'متوفر جزئيا';
    case 'preparing':
      return 'قيد التحضير';
    case 'in_delivery':
      return 'قيد التوصيل';
    case 'completed':
      return 'مكتمل';
    case 'rejected':
      return 'مرفوض';
    case 'cancelled':
      return 'ملغي';
    default:
      return status;
  }
}

IconData transferStatusIcon(String status) {
  switch (status) {
    case 'available':
      return Icons.check_circle_rounded;
    case 'submitted':
      return Icons.outbox_rounded;
    case 'approved':
      return Icons.verified_rounded;
    case 'partially_available':
      return Icons.rule_rounded;
    case 'preparing':
      return Icons.inventory_2_rounded;
    case 'in_delivery':
      return Icons.local_shipping_rounded;
    case 'completed':
      return Icons.task_alt_rounded;
    case 'rejected':
      return Icons.block_rounded;
    case 'cancelled':
      return Icons.cancel_rounded;
    default:
      return Icons.sync_alt_rounded;
  }
}

Color transferStatusColor(String status) {
  switch (status) {
    case 'available':
      return const Color(0xff16834f);
    case 'completed':
      return const Color(0xff16834f);
    case 'cancelled':
    case 'rejected':
      return const Color(0xffb13a32);
    case 'in_delivery':
      return const Color(0xff2d65b3);
    case 'preparing':
      return const Color(0xff9a6a15);
    case 'approved':
      return brandColor;
    case 'partially_available':
      return accentColor;
    default:
      return inkColor;
  }
}

const transferStatusTabs = <String>[
  'all',
  'active',
  'submitted',
  'approved',
  'partially_available',
  'preparing',
  'in_delivery',
  'completed',
  'rejected',
  'cancelled',
];

String transferTabLabel(String value) {
  switch (value) {
    case 'all':
      return 'الكل';
    case 'active':
      return 'النشطة';
    default:
      return statusLabel(value);
  }
}

String itemStatusLabel(String status) {
  switch (status) {
    case 'requested':
      return 'مطلوب';
    case 'available':
      return 'متوفر';
    case 'partially_available':
      return 'متوفر جزئيا';
    case 'unavailable':
      return 'غير متوفر';
    case 'cancelled':
      return 'ملغي';
    default:
      return status;
  }
}

String chatTypeLabel(String type) {
  switch (type) {
    case 'general':
      return 'دردشة عامة';
    case 'direct':
      return 'دردشة خاصة';
    case 'group':
      return 'مجموعة';
    case 'order':
      return 'مناقلة';
    default:
      return type;
  }
}

Future<void> enqueueNotification({
  required String title,
  required String body,
  String? employeeId,
  int? branchNum,
  Map<String, Object?> data = const {},
}) async {
  try {
    await supabase.from('ansar_notification_queue').insert({
      if (employeeId != null) 'employee_id': employeeId,
      if (branchNum != null) 'branch_num': branchNum,
      'title': title,
      'body': body,
      'data': data,
      'status': 'pending',
    });
    unawaited(kickNotificationSender());
  } catch (_) {
    // Notifications are helpful, but core workflow should not fail if queue policies are not ready.
  }
}

Future<void> enqueueNotificationsForEmployees({
  required Iterable<String> employeeIds,
  required String title,
  required String body,
  Map<String, Object?> data = const {},
}) async {
  final ids = employeeIds.toSet().where((id) => id.isNotEmpty).toList();
  if (ids.isEmpty) return;
  try {
    await supabase.from('ansar_notification_queue').insert(
          ids
              .map((id) => {
                    'employee_id': id,
                    'title': title,
                    'body': body,
                    'data': data,
                    'status': 'pending',
                  })
              .toList(),
        );
    unawaited(kickNotificationSender());
  } catch (_) {
    // Notifications are helpful, but core workflow should not fail if queue policies are not ready.
  }
}

Future<void> kickNotificationSender() async {
  try {
    await supabase.functions.invoke('send-notifications', body: {'source': 'app'});
  } catch (_) {
    // The scheduled sender will retry pending notifications if the immediate kick fails.
  }
}

bool isNotificationForSession(Map<String, dynamic> row, EmployeeSession session) {
  final data = row['data'];
  if (data is Map && data['sender_id'] == session.id) return false;
  if (data is Map && data['employee_id'] == session.id) return false;

  final employeeId = row['employee_id'] as String?;
  if (employeeId != null && employeeId.isNotEmpty) return employeeId == session.id;

  final branchNum = (row['branch_num'] as num?)?.toInt();
  if (branchNum != null) {
    return session.isAdmin || session.canManageAllBranches || branchNum == session.branchNum;
  }

  return true;
}

Future<void> enqueueChatNotification({
  required Map<String, dynamic> thread,
  required EmployeeSession sender,
  required String body,
}) async {
  final threadId = thread['id'] as String?;
  if (threadId == null) return;
  final type = thread['thread_type'] as String? ?? 'general';
  final title = type == 'general' ? 'رسالة جديدة في الدردشة العامة' : 'رسالة جديدة من ${sender.name}';
  final data = {
    'type': 'chat_message',
    'thread_id': threadId,
    'sender_id': sender.id,
  };

  if (type == 'general') {
    await enqueueNotification(
      title: title,
      body: body,
      data: data,
    );
    return;
  }

  final participants = await supabase
      .from('ansar_chat_participants')
      .select('employee_id')
      .eq('thread_id', threadId)
      .neq('employee_id', sender.id);
  await enqueueNotificationsForEmployees(
    employeeIds: participants.map((row) => row['employee_id'] as String? ?? ''),
    title: title,
    body: body,
    data: data,
  );
}

Future<void> registerDeviceForNotifications(EmployeeSession session) async {
  try {
    final messaging = FirebaseMessaging.instance;
    lastNotificationRegistrationError = null;
    await messaging.setAutoInitEnabled(true);
    final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      throw Exception('تم رفض إذن الإشعارات من إعدادات الهاتف');
    }
    final token = await getMessagingTokenWithRecovery(messaging);
    await saveDeviceToken(session, token);

    await notificationTokenRefreshSubscription?.cancel();
    notificationTokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      await saveDeviceToken(session, newToken);
    });
  } catch (error) {
    lastNotificationRegistrationError = isTemporaryMessagingServiceError(error)
        ? 'خدمة إشعارات الهاتف غير متاحة مؤقتاً، سيحاول التطبيق تلقائياً'
        : cleanError(error);
    lastNotificationRegistrationAt = DateTime.now();
    // Push setup should never block login or daily work.
  }
}

Future<String> getMessagingTokenWithRecovery(FirebaseMessaging messaging) async {
  try {
    final token = await messaging.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('لم يعط Firebase رمزاً لهذا الجهاز');
    }
    return token;
  } catch (error) {
    if (!isTooManyRegistrationsError(error)) rethrow;
    await messaging.deleteToken();
    await Future.delayed(const Duration(seconds: 2));
    final token = await messaging.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('لم يعط Firebase رمزاً جديداً بعد إعادة الضبط');
    }
    return token;
  }
}

Future<void> resetAndRegisterDeviceForNotifications(EmployeeSession session) async {
  try {
    final messaging = FirebaseMessaging.instance;
    lastNotificationRegistrationError = null;
    lastNotificationTokenPreview = null;
    await messaging.setAutoInitEnabled(true);
    await messaging.deleteToken();
    await Future.delayed(const Duration(seconds: 2));
    final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      throw Exception('تم رفض إذن الإشعارات من إعدادات الهاتف');
    }
    final token = await getMessagingTokenWithRecovery(messaging);
    await saveDeviceToken(session, token);
  } catch (error) {
    lastNotificationRegistrationError = isTemporaryMessagingServiceError(error)
        ? 'خدمة إشعارات الهاتف غير متاحة مؤقتاً، سيحاول التطبيق تلقائياً'
        : cleanError(error);
    lastNotificationRegistrationAt = DateTime.now();
  }
}

bool isTooManyRegistrationsError(Object error) {
  return error.toString().contains('TOO_MANY_REGISTRATIONS');
}

bool isTemporaryMessagingServiceError(Object error) {
  final text = error.toString();
  return text.contains('SERVICE_NOT_AVAILABLE') || text.contains('java.io.IOException');
}

Future<void> saveDeviceToken(EmployeeSession session, String token) async {
  await supabase.from('ansar_device_tokens').upsert(
    {
      'employee_id': session.id,
      'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'web'),
      'token': token,
      'device_name': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'is_active': true,
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    },
    onConflict: 'token',
  );
  lastNotificationTokenPreview = token.length <= 12 ? token : '${token.substring(0, 6)}...${token.substring(token.length - 6)}';
  lastNotificationRegistrationError = null;
  lastNotificationRegistrationAt = DateTime.now();
}

String cleanError(Object? error) {
  final text = error.toString().replaceFirst('Exception: ', '');
  if (text.contains('setState() callback argument returned a Future')) {
    return '';
  }
  if (text.length > 220) {
    return 'تعذر تنفيذ العملية الآن. حاول مرة أخرى.';
  }
  return text;
}

String? branchLogoAsset(String branchName) {
  final normalized = branchName.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.contains('طريق الشام')) return 'assets/branches/homs_sham_road.png';
  if (normalized.contains('إدلب') || normalized.contains('ادلب')) return 'assets/branches/idlib.png';
  if (normalized.contains('دمشق')) return 'assets/branches/damascus.png';
  if (normalized.contains('الباب')) return 'assets/branches/albab.png';
  if (normalized.contains('حمص')) return 'assets/branches/homs.png';
  return null;
}

String formatTime(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour < 12 ? 'ص' : 'م';
  return '$hour:$minute $period';
}

String formatDateTime(DateTime value) {
  return '${shortDate(value)} ${formatTime(value)}';
}

String reportDayLabel(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  return '${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}';
}

String attendanceDurationLabel(String? rawCheckIn) {
  final checkIn = DateTime.tryParse(rawCheckIn ?? '')?.toLocal();
  if (checkIn == null) return 'لحظات';
  final duration = DateTime.now().difference(checkIn);
  if (duration.isNegative || duration.inMinutes < 1) return 'أقل من دقيقة';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '$minutes دقيقة';
  if (minutes == 0) return '$hours ${hours == 1 ? 'ساعة' : 'ساعات'}';
  return '$hours ${hours == 1 ? 'ساعة' : 'ساعات'} و$minutes دقيقة';
}

String formatDurationCompact(Duration duration) {
  if (duration.isNegative || duration.inMinutes < 1) return 'أقل من د';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '$minutes د';
  if (minutes == 0) return '$hours س';
  return '$hours س $minutes د';
}

String formatMoneyValue(Object? value) {
  if (value == null) return '-';
  final number = (value as num?)?.toDouble() ?? double.tryParse('$value');
  if (number == null) return '$value';
  if ((number - number.roundToDouble()).abs() < 0.001) return number.toStringAsFixed(0);
  return number.toStringAsFixed(2);
}

int? nullableIntValue(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}

int intValue(Object? value, {int fallback = 0}) {
  return nullableIntValue(value) ?? fallback;
}

double doubleValue(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString().trim() ?? '') ?? fallback;
}

int? parseStoNum(Object? value) {
  final match = RegExp(r'__sto:(\d+)').firstMatch(value?.toString() ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}

int? parsePayKind(Object? value) {
  final match = RegExp(r'__pay:(\d+)').firstMatch(value?.toString() ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}

double parseDiscountItem(Object? value) {
  final match = RegExp(r'__dis:([\d.]+)').firstMatch(value?.toString() ?? '');
  return match == null ? 0 : double.tryParse(match.group(1)!) ?? 0;
}

PaymentInfo paymentLabelFromRemark(Object? remark) {
  final payKind = parsePayKind(remark);
  if (payKind == 1) return const PaymentInfo('نقدا', true);
  if (payKind == 0) return const PaymentInfo('آجل', false);
  return const PaymentInfo('غير محدد', false);
}

String discountDisplay(Map<String, dynamic> item) {
  final explicit = parseDiscountItem(item['remarki']);
  if (explicit > 0) return '${formatMoneyValue(explicit)}%';
  final quantity = (item['quantity'] as num?)?.toDouble() ?? 0;
  final price = (item['price'] as num?)?.toDouble() ?? 0;
  final value = (item['value'] as num?)?.toDouble() ?? 0;
  final gross = quantity * price;
  if (gross > 0 && value < gross - 0.001) {
    return '${formatMoneyValue((1 - value / gross) * 100)}%';
  }
  return '-';
}

class PaymentInfo {
  const PaymentInfo(this.text, this.isCash);

  final String text;
  final bool isCash;
}

String formatEventTime(Object? value) {
  if (value is! String || value.isEmpty) return '-';
  return formatDateTime(DateTime.parse(value).toLocal());
}

String eventLabel(Map<String, dynamic> event) {
  final type = event['event_type'] as String? ?? '';
  final oldStatus = event['old_status'] as String?;
  final newStatus = event['new_status'] as String?;
  final note = event['note'] as String?;
  switch (type) {
    case 'created':
      return 'إنشاء الطلب';
    case 'status_changed':
      if (oldStatus != null && newStatus != null) {
        return 'تغيير الحالة من ${statusLabel(oldStatus)} إلى ${statusLabel(newStatus)}';
      }
      return 'تغيير حالة المناقلة';
    case 'item_changed':
      return note == null ? 'تحديث بند' : 'تحديث بند: $note';
    default:
      return note ?? type;
  }
}

String shortDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$month-$day';
}

String formatDateKey(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String? emptyToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

void showSnack(BuildContext context, String message) {
  final cleaned = cleanError(message);
  if (cleaned.trim().isEmpty) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(cleaned, style: const TextStyle(color: inkColor)),
        backgroundColor: panelSurface,
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        margin: const EdgeInsets.all(14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: brandColor.withValues(alpha: 0.18)),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('تأكيد')),
          ],
        ),
      ) ??
      false;
}
