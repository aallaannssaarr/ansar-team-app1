import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' as intl;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:pushy_flutter/pushy_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ansar_config.dart';
import 'design/ansar_components.dart';
import 'design/ansar_theme.dart';
import 'design/ansar_tokens.dart';

export 'design/ansar_components.dart';
export 'design/ansar_theme.dart';
export 'design/ansar_tokens.dart';
import 'product_cache.dart';
import 'rich_notifications.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await markBackgroundChatDelivered(message.data);
  if (message.data['rich_notification']?.toString() == 'true') {
    await RichNotificationService.show(Map<String, dynamic>.from(message.data));
  }
}

@pragma('vm:entry-point')
void backgroundPushyNotificationListener(Map<String, dynamic> data) {
  final title = data['title']?.toString() ?? 'فريق الأنصار';
  final body = data['message']?.toString() ?? data['body']?.toString() ?? '';
  if (data['rich_notification']?.toString() == 'true') {
    unawaited(RichNotificationService.show(Map<String, dynamic>.from(data)));
  } else if (Platform.isAndroid) {
    Pushy.notify(title, body, data);
  }
  Pushy.clearBadge();
  unawaited(markBackgroundChatDelivered(data));
}

Future<void> markBackgroundChatDelivered(Map<String, dynamic> data) async {
  if (!isChatNotificationType(data['type']?.toString()) || data['thread_id'] == null) return;
  try {
    final preferences = await SharedPreferences.getInstance();
    final employeeId = preferences.getString('ansar_employee_id');
    if (employeeId == null || employeeId.isEmpty) return;
    final client = SupabaseClient(AnsarConfig.supabaseUrl, AnsarConfig.supabaseServiceKey);
    await client.rpc('ansar_mark_chat_delivered', params: {
      'p_employee_id': employeeId,
      'p_thread_id': '${data['thread_id']}',
    });
  } catch (_) {
    // Background delivery acknowledgement is retried when the app opens.
  }
}

final pushyNotificationClicks = StreamController<Map<String, dynamic>>.broadcast();
bool pushyInitialized = false;
Map<String, dynamic>? pendingPushyNotificationClick;

void initializePushyService() {
  if (pushyInitialized) return;
  Pushy.listen();
  Pushy.toggleInAppBanner(true);
  Pushy.setNotificationListener(backgroundPushyNotificationListener);
  Pushy.setNotificationClickListener((Map<String, dynamic> data) {
    final payload = Map<String, dynamic>.from(data);
    pendingPushyNotificationClick = payload;
    if (pushyNotificationClicks.hasListener) {
      pushyNotificationClicks.add(payload);
      pendingPushyNotificationClick = null;
    }
    Pushy.clearBadge();
  });
  pushyInitialized = true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (details) => const Material(
        color: softSurface,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, color: dangerColor, size: 42),
                  SizedBox(height: 12),
                  Text('تعذر عرض هذا الجزء', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  SizedBox(height: 5),
                  Text('أغلق الصفحة وافتحها مرة أخرى', style: TextStyle(color: mutedInk)),
                ],
              ),
            ),
          ),
        ),
      );
  appLinks ??= AppLinks();
  unawaited(initializeAppLinks());
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  if (kIsBetaBuild) {
    runApp(const AnsarApp());
    return;
  }

  await Firebase.initializeApp();
  await Supabase.initialize(
    url: AnsarConfig.supabaseUrl,
    publishableKey: AnsarConfig.supabaseServiceKey,
  );
  coreServicesFuture = Future<void>.value();
  await RichNotificationService.initialize();
  initializePushyService();
  deferredServicesReady = true;
  deferredServicesFuture = Future<void>.value();
  runApp(const AnsarApp());
}

Future<void>? coreServicesFuture;
Future<void>? deferredServicesFuture;
bool deferredServicesReady = false;
final transferDeepLinks = StreamController<String>.broadcast();
AppLinks? appLinks;
StreamSubscription<Uri>? globalAppLinkSubscription;
String? pendingTransferOrderId;

Future<void> initializeCoreServices() {
  return coreServicesFuture ??= Supabase.initialize(
    url: AnsarConfig.supabaseUrl,
    publishableKey: AnsarConfig.supabaseServiceKey,
  );
}

Future<void> initializeDeferredServices() {
  return deferredServicesFuture ??= _initializeDeferredServices();
}

Future<void> _initializeDeferredServices() async {
  try {
    await Firebase.initializeApp();
    await RichNotificationService.initialize();
    initializePushyService();
    deferredServicesReady = true;
  } catch (_) {
    deferredServicesReady = false;
    deferredServicesFuture = null;
  }
}

String? transferOrderIdFromUri(Uri uri) {
  if ({'ansarteam', 'ansarteambeta'}.contains(uri.scheme) &&
      uri.host == 'transfer' &&
      uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.last;
  }
  final segments = uri.pathSegments;
  final transferIndex = segments.indexOf('transfer');
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      transferIndex >= 0 &&
      transferIndex + 1 < segments.length) {
    return segments[transferIndex + 1];
  }
  return null;
}

void rememberTransferDeepLink(Uri uri) {
  final orderId = transferOrderIdFromUri(uri);
  if (orderId == null || orderId.isEmpty) return;
  pendingTransferOrderId = orderId;
  if (transferDeepLinks.hasListener) transferDeepLinks.add(orderId);
}

Future<void> initializeAppLinks() async {
  appLinks ??= AppLinks();
  globalAppLinkSubscription ??= appLinks!.uriLinkStream.listen(rememberTransferDeepLink);
  try {
    final initialLink = await appLinks!.getInitialLink();
    if (initialLink != null) rememberTransferDeepLink(initialLink);
  } catch (_) {
    // Deep links are optional and must never delay opening the application.
  }
}

class EmployeeSessionStore {
  static const sessionKey = 'ansar_employee_session_v1';

  static Map<String, dynamic> persistableData(Map<String, dynamic> source) {
    final data = Map<String, dynamic>.from(source);
    data.removeWhere((key, _) {
      final normalized = key.toLowerCase();
      return normalized.contains('password') ||
          normalized.contains('secret') ||
          normalized == 'pin' ||
          normalized == 'passcode';
    });
    return data;
  }

  static Future<void> save(EmployeeSession session) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(sessionKey, jsonEncode(persistableData(session.data)));
    await preferences.setString('ansar_employee_id', session.id);
  }

  static Future<EmployeeSession?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = persistableData(Map<String, dynamic>.from(decoded));
      if (data['id'] == null || data['username'] == null) return null;
      await preferences.setString(sessionKey, jsonEncode(data));
      return EmployeeSession(data);
    } catch (_) {
      await preferences.remove(sessionKey);
      return null;
    }
  }

  static Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(sessionKey);
    await preferences.remove('ansar_employee_id');
  }
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
String? activeChatThreadId;

class AnsarApp extends StatelessWidget {
  const AnsarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: kIsBetaBuild ? 'فريق الأنصار التجريبي' : 'فريق الأنصار',
      theme: buildAnsarTheme(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: const BootstrapPage(),
      ),
    );
  }
}

class BootstrapPage extends StatefulWidget {
  const BootstrapPage({super.key});

  @override
  State<BootstrapPage> createState() => _BootstrapPageState();
}

class _BootstrapPageState extends State<BootstrapPage> {
  late Future<EmployeeSession?> future;

  @override
  void initState() {
    super.initState();
    future = prepareApplication();
  }

  Future<EmployeeSession?> prepareApplication() async {
    await initializeCoreServices();
    final session = await EmployeeSessionStore.load();
    unawaited(initializeDeferredServices());
    return session;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EmployeeSession?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const BrandedStartupView();
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_rounded, color: dangerColor, size: 42),
                    const SizedBox(height: 12),
                    const Text('تعذر تجهيز التطبيق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => setState(() => future = prepareApplication()),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final session = snapshot.data;
        return session == null ? const LoginPage() : HomePage(initialSession: session, restoredSession: true);
      },
    );
  }
}

class BrandedStartupView extends StatelessWidget {
  const BrandedStartupView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: softSurface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: Image.asset('assets/logo.png', fit: BoxFit.contain),
            ),
            const SizedBox(height: 18),
            const Text('فريق الأنصار', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          ],
        ),
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
  int? get assignedBranchNum => nullableIntValue(data['branch_num']);
  int get branchNum => assignedBranchNum ?? 0;
  String get role => data['role'] as String? ?? 'employee';
  String? get avatarUrl => data['avatar_url'] as String?;
  String? get phone => data['phone'] as String?;
  String? get email => data['email'] as String?;
  String? get jobTitle => data['job_title'] as String?;
  bool get canManageEmployees => data['can_manage_employees'] == true;
  bool get canManageAllBranches => data['can_manage_all_branches'] == true;
  bool get isAdmin => role == 'admin' || canManageAllBranches;
  bool get isGeneralAdmin => role == 'admin' || canManageAllBranches;
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
    this.canManageAllBranches = false,
  });

  final String id;
  final String name;
  final String username;
  final int branchNum;
  final String role;
  final bool isActive;
  final String? avatarUrl;
  final bool canManageAllBranches;

  bool get isGeneralAdmin => role == 'admin' || canManageAllBranches;

  factory EmployeeLite.fromRow(Map<String, dynamic> row) {
    return EmployeeLite(
      id: row['id']?.toString() ?? '',
      name: (row['display_name'] ?? row['full_name'] ?? row['username'] ?? '').toString(),
      username: row['username']?.toString() ?? '',
      branchNum: nullableIntValue(row['branch_num']) ?? 0,
      role: row['role']?.toString() ?? 'employee',
      isActive: row['is_active'] != false,
      avatarUrl: row['avatar_url']?.toString(),
      canManageAllBranches: row['can_manage_all_branches'] == true,
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
      canManageAllBranches: session.canManageAllBranches,
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

  Duration displayedWorkedUntil(DateTime now, DateTime dayStart) {
    if (!isOpen) return workedUntil(now, dayStart);
    if (now.isBefore(checkIn)) return Duration.zero;
    return now.difference(checkIn);
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

  Duration displayedWorkedUntil(DateTime now, DateTime dayStart) {
    return entries.fold(
      Duration.zero,
      (total, entry) => total + entry.displayedWorkedUntil(now, dayStart),
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
  final usernameController = TextEditingController();
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

      final session = EmployeeSession(Map<String, dynamic>.from(rows.first));
      await EmployeeSessionStore.save(session);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: HomePage(initialSession: session),
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
  const HomePage({super.key, required this.initialSession, this.restoredSession = false});

  final EmployeeSession initialSession;
  final bool restoredSession;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late EmployeeSession session;
  int index = 0;
  StreamSubscription<RemoteMessage>? foregroundMessages;
  StreamSubscription<RemoteMessage>? openedMessages;
  StreamSubscription<Map<String, dynamic>>? pushyClicks;
  StreamSubscription<Map<String, dynamic>>? richNotificationClickSubscription;
  StreamSubscription<String>? transferDeepLinkSubscription;
  Timer? notificationRegistrationTimer;
  Timer? inAppNotificationsTimer;
  Timer? unreadMessagesTimer;
  RealtimeChannel? unreadMessagesChannel;
  bool openingNotification = false;
  bool notificationPermissionWarningShown = false;
  int unreadChatMessages = 0;
  final seenInAppNotificationIds = <String>{};
  DateTime inAppNotificationCursor = DateTime.now().toUtc();
  bool notificationServicesInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session = widget.initialSession;
    unawaited(EmployeeSessionStore.save(session));
    unawaited(touchEmployeePresence(session.id, online: true));
    startInAppNotificationMonitor();
    startUnreadMessagesMonitor();
    transferDeepLinkSubscription = transferDeepLinks.stream.listen(openTransferDeepLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final orderId = pendingTransferOrderId;
      if (mounted && orderId != null) unawaited(openTransferDeepLink(orderId));
    });
    unawaited(initializeHomeNotificationServices());
    if (widget.restoredSession) unawaited(refreshRestoredSession());
  }

  Future<void> initializeHomeNotificationServices() async {
    if (notificationServicesInitialized) return;
    await initializeDeferredServices();
    if (!mounted || !deferredServicesReady || notificationServicesInitialized) return;
    notificationServicesInitialized = true;
    initializePushyNotifications();
    richNotificationClickSubscription = richNotificationClicks.stream.listen((data) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(openNotificationData(data));
      });
    });
    unawaited(RichNotificationService.emitPendingClick());
    startNotificationRegistrationMonitor();
    foregroundMessages = FirebaseMessaging.onMessage.listen((message) {
      if (!mounted) return;
      if (message.data['sender_id'] == session.id) return;
      final notificationId = message.data['notification_id']?.toString();
      if (notificationId != null && notificationId.isNotEmpty) seenInAppNotificationIds.add(notificationId);
      if (isChatNotificationType(message.data['type']?.toString()) &&
          message.data['thread_id'] == activeChatThreadId) {
        return;
      }
      final title = message.notification?.title ?? 'إشعار جديد';
      final body = message.notification?.body ?? '';
      final data = Map<String, dynamic>.from(message.data);
      final isChat = isChatNotificationType(data['type']?.toString());
      if (isChat && data['thread_id'] != null) {
        unawaited(markChatNotificationDelivered(session.id, '${data['thread_id']}'));
      }
      if (data['rich_notification']?.toString() == 'true') {
        unawaited(RichNotificationService.show(data));
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Row(
              children: [
                if (isChat) ...[
                  EmployeeAvatar(
                    name: data['sender_name']?.toString() ?? 'موظف',
                    imageUrl: data['sender_avatar_url']?.toString(),
                    radius: 19,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    body.isEmpty ? title : '$title\n$body',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            action: isChat
                ? SnackBarAction(
                    label: 'فتح',
                    textColor: const Color(0xffb9f5df),
                    onPressed: () => unawaited(openChatFromNotification(data)),
                  )
                : null,
          ),
        );
    });
    openedMessages = FirebaseMessaging.onMessageOpenedApp.listen(handleOpenedNotification);
    unawaited(FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) handleOpenedNotification(message);
    }));
  }

  Future<void> refreshRestoredSession() async {
    try {
      final rows = await supabase
          .from('ansar_employees')
          .select()
          .eq('id', session.id)
          .eq('is_active', true)
          .limit(1);
      if (!mounted) return;
      if (rows.isEmpty) {
        await logout();
        return;
      }
      updateSession(EmployeeSession(Map<String, dynamic>.from(rows.first)));
    } catch (_) {
      // A saved session remains usable when the background account check cannot connect.
    }
  }

  Future<void> openTransferDeepLink(String orderId) async {
    if (!mounted || orderId.isEmpty) return;
    pendingTransferOrderId = null;
    await openNotificationData({
      'type': 'transfer_link',
      'route': 'transfer',
      'order_id': orderId,
    });
  }

  void initializePushyNotifications() {
    initializePushyService();
    pushyClicks?.cancel();
    pushyClicks = pushyNotificationClicks.stream.listen((data) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(openNotificationData(data));
      });
    });
    final pending = pendingPushyNotificationClick;
    pendingPushyNotificationClick = null;
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(openNotificationData(pending));
      });
    }
  }

  void handleOpenedNotification(RemoteMessage message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(openNotificationData(message.data));
    });
  }

  Future<void> openNotificationData(Map<String, dynamic> data) async {
    if (openingNotification || !mounted) return;
    openingNotification = true;
    try {
      final type = data['type']?.toString() ?? '';
      final route = data['route']?.toString() ?? '';
      if (type == 'chat_message' || route == 'chat') {
        setState(() => index = 4);
        await openChatNotification(context, session, data);
      } else if (type.contains('transfer') || route == 'transfer') {
        setState(() => index = 2);
        await openTransferNotification(context, session, data);
      } else {
        setState(() => index = 0);
      }
      await markNotificationOpened(data, session.id);
      unawaited(refreshUnreadChatMessages());
    } finally {
      openingNotification = false;
    }
  }

  Future<void> openChatFromNotification(Map<String, dynamic> data) async {
    await openNotificationData(data);
  }

  void updateSession(EmployeeSession value) {
    setState(() => session = value);
    unawaited(EmployeeSessionStore.save(value));
    if (notificationServicesInitialized) startNotificationRegistrationMonitor();
    startInAppNotificationMonitor();
    startUnreadMessagesMonitor();
  }

  void startUnreadMessagesMonitor() {
    unreadMessagesTimer?.cancel();
    if (unreadMessagesChannel != null) supabase.removeChannel(unreadMessagesChannel!);
    unawaited(refreshUnreadChatMessages());
    unreadMessagesTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshUnreadChatMessages());
    unreadMessagesChannel = supabase.channel('chat-unread-${session.id}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_message_receipts',
        callback: (_) => unawaited(refreshUnreadChatMessages()),
      ).subscribe();
  }

  Future<void> refreshUnreadChatMessages() async {
    try {
      final counts = await loadChatUnreadCounts(session.id);
      final total = counts.values.fold<int>(0, (sum, value) => sum + value);
      if (mounted && unreadChatMessages != total) {
        setState(() => unreadChatMessages = total);
      }
    } catch (_) {
      // The badge appears automatically after the additive chat migration is installed.
    }
  }

  void startNotificationRegistrationMonitor() {
    notificationRegistrationTimer?.cancel();
    unawaited(registerDeviceAndWarn());
    notificationRegistrationTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(registerDeviceAndWarn());
    });
  }

  Future<void> registerDeviceAndWarn() async {
    await registerDeviceForNotifications(session);
    final error = lastNotificationRegistrationError ?? '';
    if (!mounted || notificationPermissionWarningShown || !error.contains('مرفوض')) return;
    notificationPermissionWarningShown = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.notifications_off_rounded, color: dangerColor, size: 34),
        title: const Text('الإشعارات متوقفة'),
        content: const Text(
          'رفض الهاتف إذن الإشعارات. سيبقى صندوق الإشعارات داخل التطبيق متاحاً، '
          'لكن يلزم السماح بالإشعارات من إعدادات الهاتف لاستقبالها خارج التطبيق.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('فهمت'),
          ),
        ],
      ),
    );
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
        final data = notificationData(row['data']);
        if (isChatNotificationType(data['type']?.toString()) && data['thread_id'] != null) {
          unawaited(markChatNotificationDelivered(session.id, '${data['thread_id']}'));
        }
        if (isChatNotificationType(data['type']?.toString()) &&
            data['thread_id']?.toString() == activeChatThreadId) {
          continue;
        }
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
    openedMessages?.cancel();
    pushyClicks?.cancel();
    richNotificationClickSubscription?.cancel();
    transferDeepLinkSubscription?.cancel();
    notificationRegistrationTimer?.cancel();
    inAppNotificationsTimer?.cancel();
    unreadMessagesTimer?.cancel();
    if (unreadMessagesChannel != null) supabase.removeChannel(unreadMessagesChannel!);
    unawaited(touchEmployeePresence(session.id, online: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (notificationServicesInitialized) {
        startNotificationRegistrationMonitor();
        unawaited(RichNotificationService.retryPendingReplies());
      } else {
        unawaited(initializeHomeNotificationServices());
      }
      startInAppNotificationMonitor();
      unawaited(touchEmployeePresence(session.id, online: true));
      unawaited(refreshUnreadChatMessages());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(touchEmployeePresence(session.id, online: false));
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

  Future<void> logout() async {
    await notificationTokenRefreshSubscription?.cancel();
    notificationTokenRefreshSubscription = null;
    try {
      final installationId = await stableInstallationId();
      await supabase
          .from('ansar_device_installations')
          .update({'is_active': false, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('installation_id', installationId)
          .eq('employee_id', session.id);
    } catch (_) {
      // Older installations continue to work until the additive device migration is applied.
    }
    await EmployeeSessionStore.clear();
    if (!mounted) return;
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
    if (value == 'logout') await logout();
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
      NavigationDestination(
        icon: ChatNavigationIcon(count: unreadChatMessages, selected: false),
        selectedIcon: ChatNavigationIcon(count: unreadChatMessages, selected: true),
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
        onDestinationSelected: (value) {
          setState(() => index = value);
          if (value == 4) unawaited(refreshUnreadChatMessages());
        },
        destinations: destinations,
      ),
    );
  }
}

class ChatNavigationIcon extends StatelessWidget {
  const ChatNavigationIcon({super.key, required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count'),
      child: Icon(selected ? Icons.chat_rounded : Icons.chat_bubble_outline_rounded),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'فريق الأنصار',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 19),
                    ),
                    if (kIsBetaBuild)
                      Container(
                        margin: const EdgeInsets.only(top: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: warningSurface,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                        ),
                        child: const Text(
                          'نسخة تجريبية',
                          style: TextStyle(color: warningColor, fontSize: 9, fontWeight: FontWeight.w800),
                        ),
                      ),
                  ],
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
    final visible = rows
        .cast<Map<String, dynamic>>()
        .where((row) => isNotificationForSession(row, widget.session))
        .take(50)
        .toList();
    final senderIds = visible
        .map((row) => notificationData(row['data'])['sender_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (senderIds.isEmpty) return visible;
    try {
      final employees = await supabase
          .from('ansar_employees')
          .select('id, display_name, full_name, avatar_url')
          .inFilter('id', senderIds);
      final byId = {
        for (final employee in employees.cast<Map<String, dynamic>>()) '${employee['id']}': employee,
      };
      return visible.map((row) {
        final data = notificationData(row['data']);
        final employee = byId[data['sender_id']?.toString()];
        if (employee == null) return row;
        return {
          ...row,
          'data': {
            ...data,
            if ((data['sender_name']?.toString() ?? '').isEmpty)
              'sender_name': employee['display_name'] ?? employee['full_name'],
            if ((data['sender_avatar_url']?.toString() ?? '').isEmpty)
              'sender_avatar_url': employee['avatar_url'],
          },
        };
      }).toList();
    } catch (_) {
      return visible;
    }
  }

  void reload() {
    setState(() => future = loadNotifications());
  }

  Future<void> openNotification(Map<String, dynamic> row) async {
    final data = notificationData(row['data']);
    if (isChatNotificationType(data['type']?.toString())) {
      await openChatNotification(context, widget.session, data);
    } else if ((data['type']?.toString() ?? '').contains('transfer')) {
      await openTransferNotification(context, widget.session, data);
    } else if ((data['route']?.toString() ?? '') == 'attendance' && mounted) {
      Navigator.pop(context);
    }
    await markNotificationOpened({...data, 'notification_id': '${row['id']}'}, widget.session.id);
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
                        NotificationInboxTile(
                          row: rows[i],
                          onTap: () => openNotification(rows[i]),
                        ),
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
  const NotificationInboxTile({super.key, required this.row, this.onTap});

  final Map<String, dynamic> row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final created = DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal();
    final data = notificationData(row['data']);
    final type = data['type'] as String? ?? '';
    final isChat = type.contains('chat');
    final isTransfer = type.contains('transfer');
    final effectiveOnTap = (isChat || isTransfer || type.contains('attendance')) ? onTap : null;
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
      onTap: effectiveOnTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: (data['sender_id']?.toString().isNotEmpty == true ||
              data['sender_name']?.toString().isNotEmpty == true ||
              data['sender_avatar_url']?.toString().isNotEmpty == true)
          ? EmployeeAvatar(
              name: data['sender_name']?.toString() ?? 'موظف',
              imageUrl: data['sender_avatar_url']?.toString(),
              radius: 21,
            )
          : Container(
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
          ? (effectiveOnTap == null ? null : const Icon(Icons.chevron_left_rounded, color: mutedInk))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(formatTime(created), style: const TextStyle(color: mutedInk, fontSize: 11)),
                if (effectiveOnTap != null) const Icon(Icons.chevron_left_rounded, color: mutedInk, size: 18),
              ],
            ),
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
        .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url, can_manage_all_branches')
        .eq('is_active', true);
    final employees = employeeRows
        .cast<Map<String, dynamic>>()
        .map(EmployeeLite.fromRow)
        .where((employee) => !employee.isGeneralAdmin)
        .toList();
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
      branchName: widget.session.isGeneralAdmin
          ? 'إدارة جميع الفروع'
          : branchLabel(branches, widget.session.branchNum),
    );
  }

  Future<void> checkIn() async {
    final action = await showAttendanceActionSheet(context, isCheckIn: true);
    if (action == null || !mounted) return;
    final validationError = await validateAttendanceAction(
      employeeId: widget.session.id,
      effectiveAt: action.effectiveAt,
      isCheckIn: true,
    );
    if (validationError != null) {
      if (mounted) showSnack(context, validationError);
      return;
    }
    setState(() => attendanceBusy = true);
    final recordedAt = DateTime.now();
    final backdated = isAttendanceBackdated(action.effectiveAt, recordedAt);
    try {
      final values = {
        'employee_id': widget.session.id,
        'branch_num': widget.session.branchNum,
        'check_in_at': action.effectiveAt.toUtc().toIso8601String(),
        'check_in_recorded_at': recordedAt.toUtc().toIso8601String(),
        'check_in_is_backdated': backdated,
        'check_in_note': emptyToNull(action.note),
        'status': 'open',
      };
      await insertAttendanceWithCompatibility(values);
      unawaited(enqueueNotification(
        title: 'تسجيل دخول دوام',
        body: '${widget.session.name} سجل الدخول الساعة ${formatTime(action.effectiveAt)}${backdated ? ' · سُجل لاحقاً' : ''}',
        data: {
          'type': 'attendance_check_in',
          'route': 'attendance',
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'employee_id': widget.session.id,
          'branch_num': widget.session.branchNum,
          'effective_at': action.effectiveAt.toUtc().toIso8601String(),
          'is_backdated': backdated,
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
    final checkInAt = DateTime.parse(openLog['check_in_at'] as String).toLocal();
    final action = await showAttendanceActionSheet(
      context,
      isCheckIn: false,
      earliest: checkInAt,
    );
    if (action == null || !mounted) return;
    final validationError = await validateAttendanceAction(
      employeeId: widget.session.id,
      effectiveAt: action.effectiveAt,
      isCheckIn: false,
      openLog: openLog,
    );
    if (validationError != null) {
      if (mounted) showSnack(context, validationError);
      return;
    }
    setState(() => attendanceBusy = true);
    final recordedAt = DateTime.now();
    final backdated = isAttendanceBackdated(action.effectiveAt, recordedAt);
    try {
      final values = {
        'check_out_at': action.effectiveAt.toUtc().toIso8601String(),
        'check_out_recorded_at': recordedAt.toUtc().toIso8601String(),
        'check_out_is_backdated': backdated,
        'check_out_note': emptyToNull(action.note),
        'status': 'closed',
      };
      await updateAttendanceWithCompatibility(openLog['id'], values);
      unawaited(enqueueNotification(
        title: 'تسجيل خروج دوام',
        body: '${widget.session.name} سجل الخروج الساعة ${formatTime(action.effectiveAt)}${backdated ? ' · سُجل لاحقاً' : ''}',
        data: {
          'type': 'attendance_check_out',
          'route': 'attendance',
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'employee_id': widget.session.id,
          'branch_num': widget.session.branchNum,
          'effective_at': action.effectiveAt.toUtc().toIso8601String(),
          'is_backdated': backdated,
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
          final isGeneralAdmin = widget.session.isGeneralAdmin;
          final isWorking = !isGeneralAdmin && data.openLog != null;
          final attendanceTitle = isWorking
              ? 'دوامك مستمر منذ ${attendanceDurationLabel(data.openLog!['check_in_at'] as String?)}'
              : isGeneralAdmin
                  ? widget.session.name
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
                                    Icon(
                                      isGeneralAdmin ? Icons.account_balance_rounded : Icons.location_on_outlined,
                                      size: 18,
                                      color: mutedInk,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        isGeneralAdmin ? 'إدارة جميع الفروع' : 'الفرع: ${data.branchName}',
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
                              color: isGeneralAdmin
                                  ? accentColor
                                  : isWorking
                                      ? successColor
                                      : dangerColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: panelSurface, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: (isGeneralAdmin
                                          ? accentColor
                                          : isWorking
                                              ? successColor
                                              : dangerColor)
                                      .withValues(alpha: 0.18),
                                  blurRadius: 0,
                                  spreadRadius: 5,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (!isGeneralAdmin) ...[
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

class AttendanceAction {
  const AttendanceAction({required this.effectiveAt, required this.note});

  final DateTime effectiveAt;
  final String note;
}

Future<AttendanceAction?> showAttendanceActionSheet(
  BuildContext context, {
  required bool isCheckIn,
  DateTime? earliest,
}) {
  return showModalBottomSheet<AttendanceAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: panelSurface,
    builder: (_) => AttendanceActionSheet(isCheckIn: isCheckIn, earliest: earliest),
  );
}

class AttendanceActionSheet extends StatefulWidget {
  const AttendanceActionSheet({super.key, required this.isCheckIn, this.earliest});

  final bool isCheckIn;
  final DateTime? earliest;

  @override
  State<AttendanceActionSheet> createState() => _AttendanceActionSheetState();
}

class _AttendanceActionSheetState extends State<AttendanceActionSheet> {
  final note = TextEditingController();
  bool earlier = false;
  int? selectedShortcut;
  late DateTime selectedTime = DateTime.now();

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  DateTime get effectiveTime => earlier ? selectedTime : DateTime.now();

  String? get validationMessage {
    final value = effectiveTime;
    final now = DateTime.now();
    if (!sameCalendarDay(value, now)) return 'يمكن اختيار وقت من اليوم الحالي فقط';
    if (value.isAfter(now.add(const Duration(minutes: 1)))) return 'لا يمكن اختيار وقت مستقبلي';
    if (widget.earliest != null && value.isBefore(widget.earliest!)) {
      return 'وقت الخروج يجب أن يكون بعد الدخول ${formatTime(widget.earliest!)}';
    }
    return null;
  }

  void useShortcut(int minutes) {
    setState(() {
      earlier = true;
      selectedShortcut = minutes;
      selectedTime = DateTime.now().subtract(Duration(minutes: minutes));
    });
  }

  Future<void> pickExactTime() async {
    final value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(selectedTime),
      helpText: widget.isCheckIn ? 'وقت الدخول الفعلي' : 'وقت الخروج الفعلي',
    );
    if (value == null) return;
    final now = DateTime.now();
    setState(() {
      earlier = true;
      selectedShortcut = null;
      selectedTime = DateTime(now.year, now.month, now.day, value.hour, value.minute);
    });
  }

  void submit() {
    if (validationMessage != null) return;
    Navigator.pop(
      context,
      AttendanceAction(effectiveAt: effectiveTime, note: note.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final error = validationMessage;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + keyboard),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(color: borderColor, borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (widget.isCheckIn ? successColor : dangerColor).withValues(alpha: 0.11),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.isCheckIn ? Icons.login_rounded : Icons.logout_rounded,
                    color: widget.isCheckIn ? successColor : dangerColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isCheckIn ? 'تسجيل الدخول' : 'تسجيل الخروج',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 19),
                      ),
                      const Text('حدد الوقت الفعلي للحركة', style: TextStyle(color: mutedInk)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.schedule_rounded), label: Text('الآن')),
                ButtonSegment(value: true, icon: Icon(Icons.history_rounded), label: Text('وقت سابق')),
              ],
              selected: {earlier},
              onSelectionChanged: (value) {
                setState(() {
                  earlier = value.first;
                  if (earlier && selectedShortcut == null) {
                    selectedShortcut = 30;
                    selectedTime = DateTime.now().subtract(const Duration(minutes: 30));
                  }
                });
              },
            ),
            if (earlier) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final shortcut in const [30, 60, 120])
                    ChoiceChip(
                      selected: selectedShortcut == shortcut,
                      label: Text(shortcut == 30 ? 'منذ 30 دقيقة' : shortcut == 60 ? 'منذ ساعة' : 'منذ ساعتين'),
                      onSelected: (_) => useShortcut(shortcut),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.access_time_rounded, size: 18),
                    label: const Text('تحديد وقت'),
                    onPressed: pickExactTime,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                decoration: BoxDecoration(
                  color: softSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: error == null ? borderColor : dangerColor),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.event_available_rounded, color: brandColor),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'الوقت المختار: ${formatTime(selectedTime)}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error, style: const TextStyle(color: dangerColor, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'ملاحظة (اختيارية)',
                prefixIcon: Icon(Icons.notes_rounded),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: widget.isCheckIn ? successColor : dangerColor),
              onPressed: error == null ? submit : null,
              icon: Icon(widget.isCheckIn ? Icons.login_rounded : Icons.logout_rounded),
              label: Text(widget.isCheckIn ? 'تأكيد الدخول' : 'تأكيد الخروج'),
            ),
          ],
        ),
      ),
    );
  }
}

bool isAttendanceBackdated(DateTime effectiveAt, DateTime recordedAt) {
  return recordedAt.difference(effectiveAt).abs() > const Duration(minutes: 2);
}

Future<String?> validateAttendanceAction({
  required String employeeId,
  required DateTime effectiveAt,
  required bool isCheckIn,
  Map<String, dynamic>? openLog,
}) async {
  final now = DateTime.now();
  if (!sameCalendarDay(effectiveAt, now)) return 'يمكن تسجيل وقت من اليوم الحالي فقط';
  if (effectiveAt.isAfter(now.add(const Duration(minutes: 1)))) return 'لا يمكن تسجيل وقت مستقبلي';
  final openStart = openLog == null ? null : DateTime.tryParse(openLog['check_in_at']?.toString() ?? '')?.toLocal();
  if (!isCheckIn && openStart != null && effectiveAt.isBefore(openStart)) {
    return 'وقت الخروج يجب أن يكون بعد وقت الدخول';
  }

  final dayStart = DateTime(now.year, now.month, now.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final rows = await supabase
      .from('ansar_attendance_logs')
      .select('id, check_in_at, check_out_at, status')
      .eq('employee_id', employeeId)
      .gte('check_in_at', dayStart.toUtc().toIso8601String())
      .lt('check_in_at', dayEnd.toUtc().toIso8601String())
      .order('check_in_at', ascending: true);

  final proposedStart = isCheckIn ? effectiveAt : openStart ?? effectiveAt;
  final proposedEnd = isCheckIn ? now : effectiveAt;
  for (final row in rows) {
    if (openLog != null && '${row['id']}' == '${openLog['id']}') continue;
    final start = DateTime.tryParse(row['check_in_at']?.toString() ?? '')?.toLocal();
    if (start == null) continue;
    final end = DateTime.tryParse(row['check_out_at']?.toString() ?? '')?.toLocal() ?? now.add(const Duration(days: 36500));
    if (proposedStart.isBefore(end) && proposedEnd.isAfter(start)) {
      return 'يتداخل الوقت المختار مع دوام مسجل مسبقاً';
    }
  }
  return null;
}

bool missingAttendanceUpgrade(Object error) {
  final text = error.toString();
  return text.contains('check_in_recorded_at') ||
      text.contains('check_out_recorded_at') ||
      text.contains('check_in_is_backdated') ||
      text.contains('check_out_is_backdated');
}

Future<void> insertAttendanceWithCompatibility(Map<String, Object?> values) async {
  try {
    await supabase.from('ansar_attendance_logs').insert(values);
  } catch (error) {
    if (!missingAttendanceUpgrade(error)) rethrow;
    final legacy = Map<String, Object?>.from(values)
      ..remove('check_in_recorded_at')
      ..remove('check_in_is_backdated')
      ..remove('check_in_note');
    await supabase.from('ansar_attendance_logs').insert(legacy);
  }
}

Future<void> updateAttendanceWithCompatibility(Object? id, Map<String, Object?> values) async {
  try {
    await supabase.from('ansar_attendance_logs').update(values).eq('id', id!);
  } catch (error) {
    if (!missingAttendanceUpgrade(error)) rethrow;
    final legacy = Map<String, Object?>.from(values)
      ..remove('check_out_recorded_at')
      ..remove('check_out_is_backdated')
      ..remove('check_out_note');
    await supabase.from('ansar_attendance_logs').update(legacy).eq('id', id!);
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
        .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url, can_manage_all_branches');
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
      if (knownEmployee?.isGeneralAdmin == true) continue;
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
    final worked = employeeDay.displayedWorkedUntil(DateTime.now(), dayStart);
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
    final worked = employeeDay.displayedWorkedUntil(now, dayStart);
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
                      formatDurationCompact(entry.displayedWorkedUntil(now, dayStart)),
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
    employees = employees.where((employee) => !employee.isGeneralAdmin).toList();
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
          return const AnsarSkeleton(rows: 6);
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
            const AnsarPageHeader(
              title: 'التقارير',
              subtitle: 'حلّل الدوام والحضور حسب الفترة والفرع والموظف',
              icon: Icons.insert_chart_outlined_rounded,
              badge: kIsBetaBuild ? 'تجريبي' : null,
            ),
            ReportFilterPanel(
              days: days,
              branches: data.branches,
              employees: data.availableEmployees,
              selectedBranch: selectedBranch,
              selectedEmployeeId: selectedEmployeeId,
              showBranchFilter: widget.session.isAdmin,
              showEmployeeFilter: widget.session.isAdmin || widget.session.isBranchManager,
              onApply: (nextDays, nextBranch, nextEmployee) {
                setState(() {
                  days = nextDays;
                  selectedBranch = nextBranch;
                  selectedEmployeeId = nextEmployee;
                  future = loadAndRememberReports();
                });
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
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: 136,
              children: [
                AnsarMetricCard(
                  label: 'إجمالي الساعات',
                  value: data.totalHours.toStringAsFixed(1),
                  caption: 'ضمن النطاق المحدد',
                  icon: Icons.timer_rounded,
                  color: brandColor,
                ),
                AnsarMetricCard(
                  label: 'متوسط الوردية',
                  value: data.averageHours.toStringAsFixed(1),
                  caption: 'ساعة لكل وردية',
                  icon: Icons.speed_rounded,
                  color: accentColor,
                ),
                AnsarMetricCard(
                  label: 'السجلات المغلقة',
                  value: '${data.closedLogs}',
                  caption: 'وردية مكتملة',
                  icon: Icons.done_all_rounded,
                  color: successColor,
                ),
                AnsarMetricCard(
                  label: 'دوام مفتوح',
                  value: '${data.openLogs}',
                  caption: 'موظفون داخل العمل',
                  icon: Icons.pending_actions_rounded,
                  color: dangerColor,
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
    required this.onApply,
  });

  final int days;
  final Map<int, BranchOption> branches;
  final List<EmployeeLite> employees;
  final int? selectedBranch;
  final String? selectedEmployeeId;
  final bool showBranchFilter;
  final bool showEmployeeFilter;
  final void Function(int days, int? branch, String? employee) onApply;

  Future<void> showFilters(BuildContext context) async {
    var nextDays = days;
    var nextBranch = selectedBranch;
    var nextEmployee = selectedEmployeeId;
    final branchOptions = branches.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('نطاق التقرير', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    const Text('اختر الفترة والفرع والموظف ثم طبّق التصفية', style: TextStyle(color: mutedInk)),
                    const SizedBox(height: 16),
                    const Text('الفترة', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final value in const [7, 30, 60]) ...[
                          Expanded(
                            child: ReportPeriodOption(
                              days: value,
                              selected: nextDays == value,
                              onTap: () => setSheetState(() => nextDays = value),
                            ),
                          ),
                          if (value != 60) const SizedBox(width: 7),
                        ],
                      ],
                    ),
                    if (showBranchFilter) ...[
                      const SizedBox(height: 14),
                      DropdownButtonFormField<int?>(
                        key: ValueKey('sheet-branch-${nextBranch ?? 'all'}'),
                        initialValue: nextBranch,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'الفرع', prefixIcon: Icon(Icons.storefront_rounded)),
                        items: [
                          const DropdownMenuItem<int?>(value: null, child: Text('كل الفروع')),
                          ...branchOptions.map((branch) => DropdownMenuItem<int?>(value: branch.number, child: Text(branch.name))),
                        ],
                        onChanged: (value) => setSheetState(() {
                          nextBranch = value;
                          nextEmployee = null;
                        }),
                      ),
                    ],
                    if (showEmployeeFilter) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String?>(
                        key: ValueKey('sheet-employee-${nextEmployee ?? 'all'}-${employees.length}'),
                        initialValue: employees.any((employee) => employee.id == nextEmployee) ? nextEmployee : null,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'الموظف', prefixIcon: Icon(Icons.badge_outlined)),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('كل الموظفين')),
                          ...employees.map((employee) => DropdownMenuItem<String?>(value: employee.id, child: Text(employee.name))),
                        ],
                        onChanged: (value) => setSheetState(() => nextEmployee = value),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        onApply(nextDays, nextBranch, nextEmployee);
                      },
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('تطبيق التصفية'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branchName = selectedBranch == null ? 'كل الفروع' : branches[selectedBranch]?.name ?? 'فرع محدد';
    final employeeMatches = employees.where((employee) => employee.id == selectedEmployeeId).toList();
    final employeeName = selectedEmployeeId == null
        ? (showEmployeeFilter ? 'كل الموظفين' : 'حسابي')
        : employeeMatches.isEmpty
            ? 'موظف محدد'
            : employeeMatches.first.name;
    return AnsarFilterSummary(
      labels: ['آخر $days يوم', branchName, employeeName],
      onTap: () => showFilters(context),
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
  String? productCacheNotice;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final todayKey = formatDateKey(today);
    startDate = TextEditingController(text: todayKey);
    endDate = TextEditingController(text: todayKey);
    unawaited(warmQueriesCache().catchError((_) {}));
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
    observeProductCacheStatus();

    Map<int, BranchOption> branches = <int, BranchOption>{};
    try {
      branches = await loadLegacyBranchesMap();
    } catch (_) {
      // Product names remain useful even if warehouse labels are temporarily unavailable.
    }
    final matNums = productRows
        .take(40)
        .map((product) => nullableIntValue(product['mat_num']))
        .whereType<int>()
        .toList();
    List<Map<String, dynamic>> stockRows = <Map<String, dynamic>>[];
    if (matNums.isNotEmpty) {
      try {
        final rows = await supabase
            .from('product_stock')
            .select('mat_num, sto_num, quantity')
            .inFilter('mat_num', matNums);
        stockRows = rows.cast<Map<String, dynamic>>();
      } catch (_) {
        // A stock failure must never hide matching books from search results.
      }
    }
    final stockByMat = <int, List<StockResult>>{};
    for (final row in stockRows) {
      final matNum = nullableIntValue(row['mat_num']);
      final branchNum = nullableIntValue(row['sto_num']);
      if (matNum == null || branchNum == null) continue;
      stockByMat.putIfAbsent(matNum, () => <StockResult>[]).add(
            StockResult(
              branchName: branchLabel(branches, branchNum),
              quantity: doubleValue(row['quantity']),
            ),
          );
    }
    final results = <ProductResult>[];
    for (final product in productRows.take(40)) {
      final matNum = nullableIntValue(product['mat_num']);
      if (matNum == null) continue;
      final stock = stockByMat[matNum] ?? <StockResult>[];
      stock.sort((a, b) => b.quantity.compareTo(a.quantity));
      results.add(ProductResult(product: product, stock: stock));
    }
    return results;
  }

  void observeProductCacheStatus() {
    final cache = ProductSearchCache.instance;
    unawaited(cache
        .synchronize(supabase, force: cache.lastSyncError != null)
        .then<void>((_) {
      if (mounted && productCacheNotice != null) setState(() => productCacheNotice = null);
    }, onError: (_) {
      if (mounted) {
        setState(() => productCacheNotice = 'تعذر تحديث الكتب الآن. النتائج المعروضة من آخر نسخة محفوظة.');
      }
    }));
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
      final accountNum = nullableIntValue(account['num']);
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
      for (final account in await loadAccountsCached())
        nullableIntValue(account['num']): account['name']?.toString() ?? ''
    };
    return rows.cast<Map<String, dynamic>>().map((bill) {
      final accNum = nullableIntValue(bill['accnum']);
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

  Future<void> openAccountInvoices() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const Directionality(
          textDirection: TextDirection.rtl,
          child: AccountInvoicesPage(),
        ),
      ),
    );
  }

  Future<void> pickQueryDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (selected == null || !mounted) return;
    controller.text = formatDateKey(selected);
    setState(() => future = runDailySales());
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const PageStorageKey('queries-list'),
      padding: pagePadding,
      children: [
        const AnsarPageHeader(
          title: 'الاستعلامات',
          subtitle: 'وصول سريع إلى الكتب والحسابات والصناديق والمبيعات',
          icon: Icons.manage_search_rounded,
          badge: kIsBetaBuild ? 'تجريبي' : null,
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
        if (queryMode == 0 && productCacheNotice != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: warningSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accentColor.withValues(alpha: 0.28)),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_outlined, color: accentColor, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(productCacheNotice!, style: const TextStyle(color: inkColor, fontSize: 11))),
              ],
            ),
          ),
        ],
        if (queryMode == 3) ...[
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('الفترة الزمنية', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: startDate,
                          readOnly: true,
                          onTap: () => pickQueryDate(startDate),
                          decoration: const InputDecoration(
                            labelText: 'من تاريخ',
                            prefixIcon: Icon(Icons.calendar_today_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: endDate,
                          readOnly: true,
                          onTap: () => pickQueryDate(endDate),
                          decoration: const InputDecoration(
                            labelText: 'إلى تاريخ',
                            prefixIcon: Icon(Icons.event_available_outlined),
                          ),
                        ),
                      ),
                    ],
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
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: openAccountInvoices,
            icon: const Icon(Icons.manage_accounts_rounded),
            label: const Text('فواتير مورد أو زبون'),
          ),
        ],
        if (queryMode == 2 || queryMode == 3) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: submitSearch,
            icon: Icon(queryMode == 3 ? Icons.receipt_long_rounded : Icons.refresh_rounded),
            label: Text(queryMode == 3 ? 'عرض الفواتير' : 'تحديث'),
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
                return const SizedBox(height: 330, child: AnsarSkeleton(rows: 3));
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
                return const SizedBox(height: 330, child: AnsarSkeleton(rows: 3));
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
                return const SizedBox(height: 330, child: AnsarSkeleton(rows: 3));
              }
              if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: submitSearch);
              final rows = snapshot.data!;
              final total = rows.fold<double>(0, (sum, row) => sum + doubleValue(row['ras']));
              return Column(
                children: [
                  AnsarMetricCard(
                    label: 'إجمالي الصناديق',
                    value: formatMoneyValue(total),
                    caption: '${rows.length} صندوق',
                    icon: Icons.payments_rounded,
                    color: brandColor,
                  ),
                  ...rows.map((box) => Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: const BoxDecoration(color: successSurface, shape: BoxShape.circle),
                                child: const Icon(Icons.point_of_sale_rounded, color: brandColor),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      box['name'] as String? ?? 'صندوق ${box['num']}',
                                      style: const TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                    const SizedBox(height: 3),
                                    Text('رقم الصندوق ${box['num']}', style: const TextStyle(color: mutedInk, fontSize: 11)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Text('الرصيد', style: TextStyle(color: mutedInk, fontSize: 10)),
                                  Text(
                                    formatMoneyValue(box['ras']),
                                    style: TextStyle(
                                      color: doubleValue(box['ras']) < 0 ? dangerColor : brandColor,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
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
                return const SizedBox(height: 330, child: AnsarSkeleton(rows: 3));
              }
              if (snapshot.hasError) {
                return ErrorState(message: cleanError(snapshot.error), onRetry: submitSearch);
              }
              final results = snapshot.data!;
              if (results.isEmpty) {
                return const EmptyState(icon: Icons.search_off_rounded, text: 'لا توجد مبيعات اليوم');
              }
              final totalSales = results.fold<double>(0, (sum, bill) => sum + doubleValue(bill['totalvalue']));
              final cashCount = results.where((bill) => paymentLabelFromRemark(bill['remark']).isCash).length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SalesDailySummary(
                    invoices: results.length,
                    total: totalSales,
                    cashInvoices: cashCount,
                    creditInvoices: results.length - cashCount,
                  ),
                  const SizedBox(height: 14),
                  SectionHeader(title: 'الفواتير (${results.length})'),
                  Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: panelSurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < results.length; i++) ...[
                          SalesBillTile(
                            bill: results[i],
                            onTap: () => openSalesDetails(results[i]),
                          ),
                          if (i != results.length - 1) const Divider(indent: 68, height: 1),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class SalesDailySummary extends StatelessWidget {
  const SalesDailySummary({
    super.key,
    required this.invoices,
    required this.total,
    required this.cashInvoices,
    required this.creditInvoices,
  });

  final int invoices;
  final double total;
  final int cashInvoices;
  final int creditInvoices;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: brandDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('إجمالي المبيعات', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 3),
          Text(
            '\$ ${formatMoneyValue(total)}',
            style: const TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(child: SalesSummaryMetric(icon: Icons.receipt_long_rounded, label: 'فاتورة', value: '$invoices')),
              const SizedBox(width: 7),
              Expanded(child: SalesSummaryMetric(icon: Icons.payments_rounded, label: 'نقدي', value: '$cashInvoices')),
              const SizedBox(width: 7),
              Expanded(child: SalesSummaryMetric(icon: Icons.schedule_rounded, label: 'آجل', value: '$creditInvoices')),
            ],
          ),
        ],
      ),
    );
  }
}

class SalesSummaryMetric extends StatelessWidget {
  const SalesSummaryMetric({super.key, required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(7)),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 17),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white70, fontSize: 9)),
                Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SalesBillTile extends StatelessWidget {
  const SalesBillTile({super.key, required this.bill, required this.onTap});

  final Map<String, dynamic> bill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final payment = paymentLabelFromRemark(bill['remark']);
    final isPurchase = nullableIntValue(bill['kind']) == 1;
    return Material(
      color: panelSurface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (payment.isCash ? successColor : accentColor).withValues(alpha: 0.11),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  payment.isCash ? Icons.payments_rounded : Icons.schedule_rounded,
                  color: payment.isCash ? successColor : accentColor,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${isPurchase ? 'فاتورة شراء' : 'فاتورة مبيع'} ${bill['bnum']} · ${salesBookName(bill['book'])}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${bill['account_name'] ?? 'زبون عابر'} · ${payment.text} · ${bill['date'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: mutedInk, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '\$ ${formatMoneyValue(bill['totalvalue'])}',
                    style: const TextStyle(color: brandColor, fontWeight: FontWeight.w900, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  const Icon(Icons.chevron_left_rounded, color: mutedInk, size: 18),
                ],
              ),
            ],
          ),
        ),
      ),
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
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final active = selected == item.value;
          return Material(
            color: active ? brandColor : panelSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: active ? brandColor : borderColor),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onChanged(item.value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: Row(
                  children: [
                    Icon(item.icon, size: 18, color: active ? Colors.white : brandColor),
                    const SizedBox(width: 7),
                    Text(
                      item.label,
                      style: TextStyle(
                        color: active ? Colors.white : inkColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
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
      for (final account in await loadAccountsCached())
        nullableIntValue(account['num']): account['name']?.toString() ?? ''
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

class AccountInvoicesPage extends StatefulWidget {
  const AccountInvoicesPage({super.key});

  @override
  State<AccountInvoicesPage> createState() => _AccountInvoicesPageState();
}

class _AccountInvoicesPageState extends State<AccountInvoicesPage> {
  final accountSearch = TextEditingController();
  late final TextEditingController startDate;
  late final TextEditingController endDate;
  Timer? debounce;
  List<Map<String, dynamic>> suggestions = [];
  Map<String, dynamic>? selectedAccount;
  Future<List<Map<String, dynamic>>>? future;
  String period = 'month';
  String kind = 'all';
  String payment = 'all';
  bool searching = false;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    startDate = TextEditingController(text: formatDateKey(DateTime(today.year, today.month, 1)));
    endDate = TextEditingController(text: formatDateKey(today));
  }

  @override
  void dispose() {
    debounce?.cancel();
    accountSearch.dispose();
    startDate.dispose();
    endDate.dispose();
    super.dispose();
  }

  void queueAccountSearch(String value) {
    debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() => suggestions = []);
      return;
    }
    debounce = Timer(const Duration(milliseconds: 260), () => searchAccounts(query));
  }

  Future<void> searchAccounts(String value) async {
    setState(() => searching = true);
    try {
      final normalized = normalizeSearch(value);
      final words = normalized.split(' ').where((word) => word.isNotEmpty).toList();
      final numeric = int.tryParse(value);
      final accounts = await loadAccountsCached();
      final matches = accounts.where((account) {
        final number = '${account['num'] ?? ''}';
        final name = normalizeSearch(account['name']?.toString() ?? '');
        if (numeric != null) return number.contains(value);
        return words.every(name.contains);
      }).toList()
        ..sort((a, b) {
          final aName = normalizeSearch(a['name']?.toString() ?? '');
          final bName = normalizeSearch(b['name']?.toString() ?? '');
          final aScore = aName == normalized
              ? 0
              : aName.startsWith(normalized)
                  ? 1
                  : 2;
          final bScore = bName == normalized
              ? 0
              : bName.startsWith(normalized)
                  ? 1
                  : 2;
          if (aScore != bScore) return aScore.compareTo(bScore);
          return aName.compareTo(bName);
        });
      if (mounted && accountSearch.text.trim() == value) {
        setState(() {
          suggestions = matches.take(30).toList();
          searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => searching = false);
    }
  }

  void chooseAccount(Map<String, dynamic> account) {
    setState(() {
      selectedAccount = account;
      accountSearch.text = account['name']?.toString() ?? '${account['num']}';
      suggestions = [];
      future = loadBills();
    });
  }

  Future<List<Map<String, dynamic>>> loadBills() async {
    final account = selectedAccount;
    if (account == null) return [];
    final accountNumber = nullableIntValue(account['num']) ?? account['num'];
    dynamic query = supabase
        .from('bills_full')
        .select('book, bnum, date, accnum, totalvalue, remark, kind')
        .eq('accnum', accountNumber)
        .gte('date', startDate.text)
        .lte('date', endDate.text);
    if (kind != 'all') query = query.eq('kind', int.parse(kind));
    final rawRows = await query.order('date', ascending: false).order('bnum', ascending: false).limit(300);
    final rows = invoiceRowsFromResponse(rawRows);
    return rows.where((bill) {
      final info = paymentLabelFromRemark(bill['remark']);
      if (payment == 'cash') return info.isCash;
      if (payment == 'credit') return !info.isCash && info.text == 'آجل';
      return true;
    }).map<Map<String, dynamic>>((bill) => {...bill, 'account_name': account['name']}).toList();
  }

  void reload() {
    if (selectedAccount == null) return;
    setState(() => future = loadBills());
  }

  void applyPeriod(String value) {
    final today = DateTime.now();
    DateTime start = today;
    DateTime end = today;
    if (value == 'yesterday') {
      start = today.subtract(const Duration(days: 1));
      end = start;
    } else if (value == 'week') {
      start = today.subtract(const Duration(days: 6));
    } else if (value == 'month') {
      start = DateTime(today.year, today.month, 1);
    }
    setState(() {
      period = value;
      startDate.text = formatDateKey(start);
      endDate.text = formatDateKey(end);
      if (selectedAccount != null) future = loadBills();
    });
  }

  Future<void> pickDate(TextEditingController controller) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(controller.text) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      period = 'custom';
      controller.text = formatDateKey(picked);
      if (selectedAccount != null) future = loadBills();
    });
  }

  Future<String?> pickFilterValue({
    required String title,
    required String currentValue,
    required List<(String, String)> options,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            ),
            for (final option in options)
              ListTile(
                leading: Icon(
                  option.$1 == currentValue ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: option.$1 == currentValue ? brandColor : mutedInk,
                ),
                title: Text(option.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => Navigator.of(context).pop(option.$1),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> chooseKindFilter() async {
    final value = await pickFilterValue(
      title: 'نوع الفاتورة',
      currentValue: kind,
      options: const [('all', 'الكل'), ('0', 'مبيع'), ('1', 'شراء')],
    );
    if (value == null || !mounted) return;
    setState(() {
      kind = value;
      if (selectedAccount != null) future = loadBills();
    });
  }

  Future<void> choosePaymentFilter() async {
    final value = await pickFilterValue(
      title: 'طريقة الدفع',
      currentValue: payment,
      options: const [('all', 'الكل'), ('cash', 'نقداً'), ('credit', 'آجل')],
    );
    if (value == null || !mounted) return;
    setState(() {
      payment = value;
      if (selectedAccount != null) future = loadBills();
    });
  }

  String get kindLabel => switch (kind) {
        '0' => 'مبيع',
        '1' => 'شراء',
        _ => 'الكل',
      };

  String get paymentLabel => switch (payment) {
        'cash' => 'نقداً',
        'credit' => 'آجل',
        _ => 'الكل',
      };

  @override
  Widget build(BuildContext context) {
    const periods = [
      ('today', 'اليوم'),
      ('yesterday', 'الأمس'),
      ('week', 'الأسبوع'),
      ('month', 'الشهر'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('فواتير مورد أو زبون')),
      body: ListView(
        padding: pagePadding,
        children: [
          const AnsarPageHeader(
            title: 'فواتير الحساب',
            subtitle: 'مبيعات ومشتريات حساب محدد ضمن الفترة التي تختارها',
            icon: Icons.manage_accounts_rounded,
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: accountSearch,
                    decoration: InputDecoration(
                      labelText: 'المورد أو الزبون',
                      hintText: 'اكتب الاسم أو رقم الحساب',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: searching
                          ? const Padding(
                              padding: EdgeInsets.all(13),
                              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : null,
                    ),
                    onChanged: (value) {
                      setState(() {
                        selectedAccount = null;
                        future = null;
                      });
                      queueAccountSearch(value);
                    },
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
                          final account = suggestions[index];
                          return ListTile(
                            leading: const Icon(Icons.account_circle_outlined, color: brandColor),
                            title: Text(account['name']?.toString() ?? 'حساب'),
                            subtitle: Text('رقم ${account['num']}'),
                            onTap: () => chooseAccount(account),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (selectedAccount != null) ...[
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(selectedAccount!['name']?.toString() ?? 'حساب', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                    Text('رقم الحساب ${selectedAccount!['num']}', style: const TextStyle(color: mutedInk)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: periods.map((item) {
                        final selected = period == item.$1;
                        return selected
                            ? FilledButton.icon(
                                onPressed: () => applyPeriod(item.$1),
                                icon: const Icon(Icons.check_rounded, size: 17),
                                label: Text(item.$2),
                              )
                            : OutlinedButton(
                                onPressed: () => applyPeriod(item.$1),
                                child: Text(item.$2),
                              );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => pickDate(startDate),
                            icon: const Icon(Icons.calendar_today_outlined, size: 18),
                            label: Text('من ${startDate.text}', overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => pickDate(endDate),
                            icon: const Icon(Icons.event_available_outlined, size: 18),
                            label: Text('إلى ${endDate.text}', overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: chooseKindFilter,
                            icon: const Icon(Icons.receipt_long_outlined, size: 18),
                            label: Text('النوع: $kindLabel'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: choosePaymentFilter,
                            icon: const Icon(Icons.payments_outlined, size: 18),
                            label: Text('الدفع: $paymentLabel'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: reload,
                      icon: const Icon(Icons.search_rounded),
                      label: const Text('عرض الفواتير'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (future != null)
              FutureBuilder<List<Map<String, dynamic>>>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) return const AnsarSkeleton(rows: 4);
                  if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: reload);
                  final bills = snapshot.data ?? [];
                  if (bills.isEmpty) return const EmptyState(icon: Icons.receipt_long_outlined, text: 'لا توجد فواتير ضمن هذه الفترة');
                  final total = bills.fold<double>(0, (sum, bill) => sum + doubleValue(bill['totalvalue']));
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: AccountInvoiceMetric(label: 'الفواتير', value: '${bills.length}', icon: Icons.receipt_long_rounded)),
                          const SizedBox(width: 7),
                          Expanded(child: AccountInvoiceMetric(label: 'الإجمالي', value: '\$ ${formatMoneyValue(total)}', icon: Icons.summarize_rounded)),
                          const SizedBox(width: 7),
                          Expanded(child: AccountInvoiceMetric(label: 'المتوسط', value: '\$ ${formatMoneyValue(total / bills.length)}', icon: Icons.analytics_outlined)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: panelSurface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: borderColor),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < bills.length; i++) ...[
                              SalesBillTile(
                                bill: bills[i],
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => Directionality(
                                      textDirection: TextDirection.rtl,
                                      child: SalesBillDetailsPage(bill: bills[i]),
                                    ),
                                  ),
                                ),
                              ),
                              if (i != bills.length - 1) const Divider(indent: 68, height: 1),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}

class AccountInvoiceMetric extends StatelessWidget {
  const AccountInvoiceMetric({super.key, required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 86),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: softSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: brandColor),
          const SizedBox(height: 5),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: mutedInk, fontSize: 10)),
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
  bool pdfBusy = false;

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
        .eq('kind', nullableIntValue(widget.bill['kind']) ?? 0)
        .order('item', ascending: true);
    final items = rows.cast<Map<String, dynamic>>();
    final matNums = items.map((row) => nullableIntValue(row['matnum'])).whereType<int>().toSet().toList();
    final products = matNums.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase.from('products').select('mat_num, name').inFilter('mat_num', matNums);
    final names = <int, String>{};
    for (final product in products.cast<Map<String, dynamic>>()) {
      final matNum = nullableIntValue(product['mat_num']);
      if (matNum != null) names[matNum] = product['name']?.toString() ?? '';
    }
    final branches = await loadLegacyBranchesMap();
    return SalesBillDetailsData(
      branches: branches,
      items: items.map((item) => {...item, 'product_name': names[nullableIntValue(item['matnum'])]}).toList(),
    );
  }

  String get invoiceFileName {
    final kind = nullableIntValue(widget.bill['kind']) == 1 ? 'purchase' : 'sale';
    final book = '${widget.bill['book'] ?? 'book'}'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    final number = '${widget.bill['bnum'] ?? 'invoice'}'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return 'ansar-$kind-$book-$number.pdf';
  }

  Future<void> printInvoice(SalesBillDetailsData data) async {
    setState(() => pdfBusy = true);
    try {
      final bytes = await buildInvoicePdf(data);
      try {
        final opened = await Printing.layoutPdf(
          name: invoiceFileName,
          onLayout: (_) async => bytes,
        );
        if (!opened) await shareInvoiceBytes(bytes);
      } catch (_) {
        await shareInvoiceBytes(bytes);
        if (mounted) showSnack(context, 'تم إنشاء ملف الفاتورة ويمكنك حفظه أو مشاركته');
      }
    } catch (error) {
      if (mounted) showSnack(context, 'تعذر طباعة الفاتورة. ${cleanError(error)}');
    } finally {
      if (mounted) setState(() => pdfBusy = false);
    }
  }

  Future<void> shareInvoice(SalesBillDetailsData data) async {
    setState(() => pdfBusy = true);
    try {
      final bytes = await buildInvoicePdf(data);
      await shareInvoiceBytes(bytes);
    } catch (error) {
      if (mounted) showSnack(context, 'تعذر مشاركة الفاتورة. ${cleanError(error)}');
    } finally {
      if (mounted) setState(() => pdfBusy = false);
    }
  }

  Future<void> shareInvoiceBytes(Uint8List bytes) async {
    final directory = await Directory.systemTemp.createTemp('ansar-invoice-');
    final file = File('${directory.path}${Platform.pathSeparator}$invoiceFileName');
    await file.writeAsBytes(bytes, flush: true);
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf', name: invoiceFileName)],
        subject: 'فاتورة ${widget.bill['bnum'] ?? ''}',
        text: 'فاتورة ${widget.bill['account_name'] ?? widget.bill['accnum'] ?? ''}',
      );
    } catch (_) {
      await Printing.sharePdf(bytes: bytes, filename: invoiceFileName);
    }
  }

  Future<Uint8List> buildInvoicePdf(SalesBillDetailsData data) async {
    try {
      return await buildRichInvoicePdf(data);
    } catch (_) {
      return buildFallbackInvoicePdf(data);
    }
  }

  Future<Uint8List> buildRichInvoicePdf(SalesBillDetailsData data) async {
    final fontBytes = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
    final logoBytes = await rootBundle.load('assets/logo.png');
    final font = pw.Font.ttf(fontBytes);
    final logo = pw.MemoryImage(
      logoBytes.buffer.asUint8List(logoBytes.offsetInBytes, logoBytes.lengthInBytes),
    );
    final document = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: font));
    final isPurchase = nullableIntValue(widget.bill['kind']) == 1;
    final total = doubleValue(widget.bill['totalvalue']);
    final gross = data.items.fold<double>(
      0,
      (sum, item) => sum + doubleValue(item['quantity']) * doubleValue(item['price']),
    );
    final discount = gross > total && gross > 0 ? gross - total : 0.0;
    final payment = paymentLabelFromRemark(widget.bill['remark']);
    final stoNum = parseStoNum(widget.bill['remark']);
    final branchName = stoNum == null ? salesBookName(widget.bill['book']) : branchLabel(data.branches, stoNum);
    final itemRows = data.items.asMap().entries.map(
      (entry) => invoicePdfRtlRow(entry.value, entry.key),
    ).toList();

    document.addPage(
      pw.MultiPage(
        textDirection: pw.TextDirection.rtl,
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 26, 28, 30),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerLeft,
          child: pw.Text(
            'صفحة ${context.pageNumber} من ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Container(
                width: 58,
                height: 58,
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
                    pw.Text('مكتبة الأنصار', style: pw.TextStyle(fontSize: 27, fontWeight: pw.FontWeight.bold)),
                    pw.Text(branchName, style: pw.TextStyle(fontSize: 13, color: const PdfColor.fromInt(0xffc43c2f))),
                  ],
                ),
              ),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: pw.BoxDecoration(
                  color: const PdfColor.fromInt(0xffe7f4f1),
                  borderRadius: pw.BorderRadius.circular(5),
                ),
                child: pw.Text(
                  isPurchase ? 'فاتورة شراء' : 'فاتورة مبيع',
                  style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xff087568)),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              border: pw.Border.all(color: PdfColors.grey300),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Wrap(
              spacing: 24,
              runSpacing: 7,
              children: [
                pw.Text('الحساب: ${widget.bill['account_name'] ?? 'حساب ${widget.bill['accnum'] ?? '-'}'}'),
                pw.Text('الدفع: ${payment.text}'),
                pw.Text('التاريخ: ${widget.bill['date'] ?? '-'}'),
                pw.Text('رقم الفاتورة: ${widget.bill['bnum'] ?? '-'}', style: pw.TextStyle(color: const PdfColor.fromInt(0xffc43c2f))),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: invoicePdfRtlHeaders,
            data: itemRows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff087568)),
            oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xfff4f8f7)),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 7),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.6),
            columnWidths: const {
              0: pw.FlexColumnWidth(1.7),
              1: pw.FlexColumnWidth(1.8),
              2: pw.FlexColumnWidth(1.2),
              3: pw.FlexColumnWidth(1.5),
              4: pw.FlexColumnWidth(1.2),
              5: pw.FlexColumnWidth(4),
              6: pw.FixedColumnWidth(24),
            },
          ),
          pw.SizedBox(height: 14),
          pw.Align(
            alignment: pw.Alignment.centerLeft,
            child: pw.Container(
              width: 245,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                children: [
                  pdfTotalLine('الإجمالي قبل الحسم', '\$ ${formatMoneyValue(gross)}'),
                  if (discount > 0) ...[
                    pw.SizedBox(height: 5),
                    pdfTotalLine('الحسم', '- \$ ${formatMoneyValue(discount)}', color: const PdfColor.fromInt(0xffd98218)),
                  ],
                  pw.Divider(color: PdfColors.grey300),
                  pdfTotalLine(
                    'صافي الفاتورة',
                    '\$ ${formatMoneyValue(total)}',
                    color: const PdfColor.fromInt(0xff087568),
                    bold: true,
                  ),
                ],
              ),
            ),
          ),
          pw.SizedBox(height: 12),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: const PdfColor.fromInt(0xffeef5fb),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Text(
              arabicUsdAmountInWords(total),
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(color: const PdfColor.fromInt(0xff1d5d8f), fontWeight: pw.FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  Future<Uint8List> buildFallbackInvoicePdf(SalesBillDetailsData data) async {
    return buildPortableInvoicePdf(widget.bill, data);
  }

  @override
  Widget build(BuildContext context) {
    final isPurchase = nullableIntValue(widget.bill['kind']) == 1;
    return Scaffold(
      appBar: AppBar(title: Text('${isPurchase ? 'فاتورة شراء' : 'فاتورة مبيع'} ${widget.bill['bnum']}')),
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
          final total = doubleValue(widget.bill['totalvalue']);
          final gross = items.fold<double>(
            0,
            (sum, item) => sum + (doubleValue(item['quantity']) * doubleValue(item['price'])),
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
                                Text(
                                  '${isPurchase ? 'فاتورة شراء' : 'فاتورة مبيع'} ${widget.bill['bnum']}',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                                ),
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
                          InfoChip(icon: Icons.summarize_rounded, label: 'الإجمالي \$ ${formatMoneyValue(total)}'),
                          if (discount > 0)
                            InfoChip(
                              icon: Icons.percent_rounded,
                              label: 'حسم \$ ${formatMoneyValue(discount)}',
                              color: accentColor,
                            ),
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
                InvoiceItemsTable(items: items, branches: data.branches),
              const SizedBox(height: 12),
              InvoiceTotals(gross: gross, discount: discount, total: total),
              const SizedBox(height: 10),
              AnsarInlineNotice(
                icon: Icons.text_fields_rounded,
                message: arabicUsdAmountInWords(total),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: pdfBusy ? null : () => printInvoice(data),
                      icon: const Icon(Icons.print_rounded),
                      label: const Text('طباعة PDF'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: pdfBusy ? null : () => shareInvoice(data),
                      icon: pdfBusy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.share_rounded),
                      label: const Text('مشاركة PDF'),
                    ),
                  ),
                ],
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

// PDF tables lay out their stored columns in the opposite visual order when
// the page direction is RTL. Keep the stored order reversed so the rendered
// invoice starts with the row number on the right and ends with the total on
// the left.
const invoicePdfRtlHeaders = <String>[
  'الإجمالي',
  'صافي سعر الوحدة',
  'الحسم %',
  'السعر',
  'الكمية',
  'البيان',
  '#',
];

List<String> invoicePdfRtlRow(Map<String, dynamic> item, int index) {
  final quantity = doubleValue(item['quantity']);
  final price = doubleValue(item['price']);
  final value = doubleValue(item['value']);
  final productName = item['product_name']?.toString();
  final discountPercent = invoiceItemDiscountPercent(item);
  final netUnit = quantity == 0 ? 0 : value / quantity;
  return [
    '\$ ${formatMoneyValue(value)}',
    '\$ ${formatMoneyValue(netUnit)}',
    discountPercent <= 0 ? '-' : '${formatMoneyValue(discountPercent)}%',
    '\$ ${formatMoneyValue(price)}',
    formatMoneyValue(quantity),
    productName == null || productName.isEmpty ? 'مادة ${item['matnum'] ?? '-'}' : productName,
    '${index + 1}',
  ];
}

Future<Uint8List> buildPortableInvoicePdf(
  Map<String, dynamic> bill,
  SalesBillDetailsData data,
) async {
  final fontBytes = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
  final font = pw.Font.ttf(fontBytes);
  final document = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: font));
  final isPurchase = nullableIntValue(bill['kind']) == 1;
  final total = doubleValue(bill['totalvalue']);
  final payment = paymentLabelFromRemark(bill['remark']);
  final rows = data.items.asMap().entries.map((entry) {
    final row = invoicePdfRtlRow(entry.value, entry.key);
    row[5] = shortPdfText(row[5], 70);
    return row;
  }).toList();
  document.addPage(
    pw.MultiPage(
      textDirection: pw.TextDirection.rtl,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.Text('صفحة ${context.pageNumber} من ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
      ),
      build: (_) => [
        pw.Text('مكتبة الأنصار', style: pw.TextStyle(fontSize: 25, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.Text(isPurchase ? 'فاتورة شراء' : 'فاتورة مبيع', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 10),
        pw.Text('رقم الفاتورة: ${bill['bnum'] ?? '-'}'),
        pw.Text('الحساب: ${bill['account_name'] ?? 'حساب ${bill['accnum'] ?? '-'}'}'),
        pw.Text('التاريخ: ${bill['date'] ?? '-'} · الدفع: ${payment.text}'),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          headers: invoicePdfRtlHeaders,
          data: rows,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff087568)),
          border: pw.TableBorder.all(color: PdfColors.grey400),
          cellAlignment: pw.Alignment.centerRight,
          headerAlignment: pw.Alignment.centerRight,
          columnWidths: const {
            0: pw.FlexColumnWidth(1.7),
            1: pw.FlexColumnWidth(1.8),
            2: pw.FlexColumnWidth(1.2),
            3: pw.FlexColumnWidth(1.5),
            4: pw.FlexColumnWidth(1.2),
            5: pw.FlexColumnWidth(4),
            6: pw.FixedColumnWidth(24),
          },
        ),
        pw.SizedBox(height: 14),
        pw.Text('الصافي: \$ ${formatMoneyValue(total)}', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.Text(arabicUsdAmountInWords(total), textAlign: pw.TextAlign.center),
      ],
    ),
  );
  return document.save();
}

List<Map<String, dynamic>> invoiceRowsFromResponse(Object? value) {
  if (value is! List) return <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);
}

class InvoiceItemsTable extends StatelessWidget {
  const InvoiceItemsTable({super.key, required this.items, required this.branches});

  final List<Map<String, dynamic>> items;
  final Map<int, BranchOption> branches;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: panelSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 9),
            child: Row(
              children: [
                Icon(Icons.receipt_long_rounded, color: brandColor, size: 20),
                SizedBox(width: 7),
                Text('بنود الفاتورة', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
              ],
            ),
          ),
          const InvoiceTableRow(
            header: true,
            name: 'المادة',
            quantity: 'الكمية',
            price: 'السعر',
            discount: 'الحسم',
            total: 'القيمة',
          ),
          for (var i = 0; i < items.length; i++)
            InvoiceTableRow.fromItem(
              item: items[i],
              index: i + 1,
              branchName: () {
                final stoNum = parseStoNum(items[i]['remarki']);
                return stoNum == null ? null : branchLabel(branches, stoNum);
              }(),
              shaded: i.isOdd,
            ),
        ],
      ),
    );
  }
}

class InvoiceTableRow extends StatelessWidget {
  const InvoiceTableRow({
    super.key,
    required this.name,
    required this.quantity,
    required this.price,
    required this.discount,
    required this.total,
    this.subtitle,
    this.header = false,
    this.shaded = false,
  });

  factory InvoiceTableRow.fromItem({
    required Map<String, dynamic> item,
    required int index,
    required String? branchName,
    required bool shaded,
  }) {
    final productName = item['product_name']?.toString();
    return InvoiceTableRow(
      name: '$index. ${productName == null || productName.isEmpty ? 'مادة ${item['matnum']}' : productName}',
      subtitle: branchName == null ? 'رقم ${item['matnum'] ?? '-'}' : 'رقم ${item['matnum'] ?? '-'} · $branchName',
      quantity: formatMoneyValue(item['quantity']),
      discount: discountDisplay(item),
      price: '\$ ${formatMoneyValue(item['price'])}',
      total: '\$ ${formatMoneyValue(item['value'])}',
      shaded: shaded,
    );
  }

  final String name;
  final String? subtitle;
  final String quantity;
  final String price;
  final String discount;
  final String total;
  final bool header;
  final bool shaded;

  @override
  Widget build(BuildContext context) {
    final textColor = header ? Colors.white : inkColor;
    return Container(
      constraints: BoxConstraints(minHeight: header ? 38 : 56),
      color: header
          ? brandDark
          : shaded
              ? softSurface
              : panelSurface,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  name,
                  maxLines: header ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor, fontSize: header ? 10 : 11, fontWeight: FontWeight.w800),
                ),
                if (!header && subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: mutedInk, fontSize: 8),
                  ),
              ],
            ),
          ),
          InvoiceValueCell(value: quantity, flex: 2, header: header),
          InvoiceValueCell(value: price, flex: 3, header: header),
          InvoiceValueCell(
            value: discount,
            flex: 2,
            header: header,
            color: !header && discount != '-' ? accentColor : null,
          ),
          InvoiceValueCell(value: total, flex: 3, header: header, strong: !header),
        ],
      ),
    );
  }
}

class InvoiceValueCell extends StatelessWidget {
  const InvoiceValueCell({
    super.key,
    required this.value,
    required this.flex,
    required this.header,
    this.strong = false,
    this.color,
  });

  final String value;
  final int flex;
  final bool header;
  final bool strong;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: header ? Colors.white : color ?? (strong ? brandColor : inkColor),
            fontSize: header ? 9 : 10,
            fontWeight: header || strong ? FontWeight.w900 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class InvoiceTotals extends StatelessWidget {
  const InvoiceTotals({super.key, required this.gross, required this.discount, required this.total});

  final double gross;
  final double discount;
  final double total;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 245,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panelSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          children: [
            InvoiceTotalLine(label: 'الإجمالي قبل الحسم', value: '\$ ${formatMoneyValue(gross)}'),
            if (discount > 0) ...[
              const SizedBox(height: 6),
              InvoiceTotalLine(label: 'الحسم', value: '- \$ ${formatMoneyValue(discount)}', color: accentColor),
            ],
            const Divider(height: 18),
            InvoiceTotalLine(label: 'صافي الفاتورة', value: '\$ ${formatMoneyValue(total)}', color: brandColor, strong: true),
          ],
        ),
      ),
    );
  }
}

class InvoiceTotalLine extends StatelessWidget {
  const InvoiceTotalLine({
    super.key,
    required this.label,
    required this.value,
    this.color = inkColor,
    this.strong = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: TextStyle(color: strong ? inkColor : mutedInk, fontSize: 11))),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: strong ? 15 : 12)),
      ],
    );
  }
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

  Future<void> openDetails(BuildContext context) async {
    final product = result.product;
    final prices = [
      ('سعر الجرد', product['jard_price']),
      ('السعر القائم', product['regular_price']),
      ('سعر المكتبات', product['price1']),
      ('سعر المعاهد', product['price2']),
      ('سعر المفرق', product['price3']),
    ].where((item) => hasVisiblePrice(item.$2)).toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.88,
          minChildSize: 0.55,
          maxChildSize: 0.96,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: successSurface, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.menu_book_outlined, color: brandColor),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(product['name']?.toString() ?? 'بدون اسم', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 3),
                          Text('رقم المادة ${product['mat_num']} · الكمية ${formatMoneyValue(product['quantity'])}', style: const TextStyle(color: mutedInk, fontSize: 12)),
                        ],
                      ),
                    ),
                    IconButton(tooltip: 'إغلاق', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (prices.isNotEmpty)
                      ProductDetailsTable(
                        title: 'الأسعار المعتمدة',
                        icon: Icons.sell_outlined,
                        headers: const ['نوع السعر', 'القيمة'],
                        rows: prices.map((price) => [price.$1, formatMoneyValue(price.$2)]).toList(),
                      ),
                    if (prices.isNotEmpty) const SizedBox(height: 14),
                    if (result.stock.isEmpty)
                      const EmptyState(icon: Icons.inventory_2_outlined, text: 'لا توجد كميات حسب الفروع')
                    else
                      ProductStockTable(stock: result.stock),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final product = result.product;
    final matNum = product['mat_num'];
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: successSurface, borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.menu_book_outlined, color: brandColor),
        ),
        title: Text(product['name']?.toString() ?? 'بدون اسم', style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text('رقم المادة $matNum · الكمية ${formatMoneyValue(product['quantity'])}', style: const TextStyle(color: mutedInk, fontSize: 12)),
        trailing: const Icon(Icons.chevron_left_rounded, color: mutedInk),
        onTap: () => openDetails(context),
      ),
    );
  }
}

class ProductDetailsTable extends StatelessWidget {
  const ProductDetailsTable({
    super.key,
    required this.title,
    required this.icon,
    required this.headers,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<String> headers;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: panelSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Container(
            color: brandColor.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, color: brandColor, size: 19),
                const SizedBox(width: 7),
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800))),
              ],
            ),
          ),
          ProductTableRow(values: headers, header: true),
          for (var i = 0; i < rows.length; i++)
            ProductTableRow(values: rows[i], shaded: i.isOdd),
        ],
      ),
    );
  }
}

class ProductStockTable extends StatelessWidget {
  const ProductStockTable({super.key, required this.stock});

  final List<StockResult> stock;

  @override
  Widget build(BuildContext context) {
    final rows = stock.map((item) {
      final state = item.quantity < 0
          ? 'رصيد سالب'
          : item.quantity == 0
              ? 'غير متوفر'
              : 'متوفر';
      return [item.branchName, formatMoneyValue(item.quantity), state];
    }).toList();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: panelSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Container(
            color: successSurface.withValues(alpha: 0.55),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: const Row(
              children: [
                Icon(Icons.inventory_2_outlined, color: brandColor, size: 19),
                SizedBox(width: 7),
                Expanded(child: Text('الرصيد حسب الفرع', style: TextStyle(fontWeight: FontWeight.w800))),
              ],
            ),
          ),
          const ProductTableRow(values: ['الفرع', 'الرصيد', 'الحالة'], header: true),
          for (var i = 0; i < rows.length; i++)
            ProductTableRow(
              values: rows[i],
              shaded: i.isOdd,
              danger: stock[i].quantity < 0,
            ),
        ],
      ),
    );
  }
}

class ProductTableRow extends StatelessWidget {
  const ProductTableRow({
    super.key,
    required this.values,
    this.header = false,
    this.shaded = false,
    this.danger = false,
  });

  final List<String> values;
  final bool header;
  final bool shaded;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: danger
          ? dangerColor.withValues(alpha: 0.07)
          : shaded
              ? softSurface
              : panelSurface,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++) ...[
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Text(
                values[i],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: i == 0 ? TextAlign.start : TextAlign.center,
                style: TextStyle(
                  color: danger && i > 0 ? dangerColor : header ? mutedInk : inkColor,
                  fontSize: header ? 11 : 12,
                  fontWeight: header || i > 0 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            if (i != values.length - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

bool hasVisiblePrice(Object? value) {
  if (value == null) return false;
  final number = value is num ? value.toDouble() : double.tryParse(value.toString());
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
  const InfoChip({super.key, required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16, color: color),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: color == null ? null : TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
      backgroundColor: color?.withValues(alpha: 0.09),
      side: color == null ? null : BorderSide(color: color!.withValues(alpha: 0.22)),
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
              final generalAdmin = employee['role'] == 'admin' || employee['can_manage_all_branches'] == true;
              return ListTile(
                leading: EmployeeAvatar(
                  name: employee['display_name'] ?? employee['full_name'] ?? '',
                  imageUrl: employee['avatar_url'] as String?,
                ),
                title: Text(employee['display_name'] ?? employee['full_name'] ?? ''),
                subtitle: Text(
                  generalAdmin
                      ? 'إدارة جميع الفروع · مدير عام'
                      : '${branchLabel(data.branches, branchNum)} · ${roleLabel(employee['role']?.toString() ?? 'employee')}',
                ),
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
      role = employee['can_manage_all_branches'] == true
          ? 'admin'
          : employee['role'] as String? ?? 'employee';
      branchNum = (employee['branch_num'] as num?)?.toInt();
    } else if (widget.branches.isNotEmpty) {
      branchNum = widget.branches.keys.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isGeneralAdmin = role == 'admin';
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
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: 'الصلاحية'),
              items: const [
                DropdownMenuItem(value: 'employee', child: Text('موظف')),
                DropdownMenuItem(value: 'branch_manager', child: Text('مدير فرع')),
                DropdownMenuItem(value: 'admin', child: Text('مدير عام')),
              ],
              onChanged: (value) {
                setState(() {
                  role = value ?? 'employee';
                  if (role == 'admin') {
                    branchNum = null;
                  } else if (branchNum == null && widget.branches.isNotEmpty) {
                    branchNum = widget.branches.keys.first;
                  }
                });
              },
            ),
            if (isGeneralAdmin)
              const AnsarInlineNotice(
                message: 'المدير العام يدير جميع الفروع ولا يرتبط بفرع أو دوام.',
                icon: Icons.account_balance_rounded,
              )
            else
              DropdownButtonFormField<int>(
                initialValue: branchNum,
                decoration: const InputDecoration(labelText: 'الفرع'),
                items: widget.branches.values
                    .map((branch) => DropdownMenuItem(value: branch.number, child: Text(branch.label)))
                    .toList(),
                onChanged: (value) => setState(() => branchNum = value),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: !isGeneralAdmin && branchNum == null
              ? null
              : () {
                  Navigator.pop(context, {
                    'full_name': name.text.trim(),
                    'display_name': name.text.trim(),
                    'username': username.text.trim(),
                    'phone': emptyToNull(phone.text),
                    'email': emptyToNull(email.text),
                    'job_title': emptyToNull(jobTitle.text),
                    'branch_num': isGeneralAdmin ? null : branchNum,
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
    List<Map<String, dynamic>> tokens;
    try {
      final rows = await supabase
          .from('ansar_device_installations')
          .select('id, installation_id, employee_id, platform, device_name, permission_status, preferred_provider, fcm_token, pushy_token, firebase_failures, pushy_failures, is_active, last_seen_at, last_success_at, created_at')
          .order('last_seen_at', ascending: false)
          .limit(50);
      tokens = rows.cast<Map<String, dynamic>>();
    } catch (_) {
      final rows = await supabase
          .from('ansar_device_tokens')
          .select('id, employee_id, platform, is_active, last_seen_at, created_at')
          .order('last_seen_at', ascending: false)
          .limit(50);
      tokens = rows.cast<Map<String, dynamic>>();
    }
    final queue = await supabase
        .from('ansar_notification_queue')
        .select('id, title, body, status, error_message, created_at, sent_at')
        .order('created_at', ascending: false)
        .limit(30);
    List<Map<String, dynamic>> deliveries = [];
    try {
      final rows = await supabase
          .from('ansar_notification_deliveries')
          .select('notification_id, installation_id, employee_id, provider, status, attempts, last_error, sent_at, created_at')
          .order('created_at', ascending: false)
          .limit(40);
      deliveries = rows.cast<Map<String, dynamic>>();
    } catch (_) {
      // Delivery details appear after the platform migration is installed.
    }
    return NotificationDiagnosticsData(tokens: tokens, queue: queue.cast<Map<String, dynamic>>(), deliveries: deliveries);
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
        final pending = data.queue.where((row) => {'pending', 'retrying'}.contains(row['status'])).length;
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
                      title: Text(row['device_name'] as String? ?? row['platform'] as String? ?? 'android'),
                      subtitle: Text(
                        [
                          'Firebase: ${row['fcm_token'] == null ? 'غير مسجل' : 'مسجل'} · Pushy: ${row['pushy_token'] == null ? 'غير مسجل' : 'مسجل'}',
                          'الإذن: ${row['permission_status'] ?? 'غير معروف'} · المفضل: ${row['preferred_provider'] ?? 'firebase'}',
                          row['last_seen_at'] as String? ?? row['created_at'] as String? ?? '-',
                        ].join('\n'),
                      ),
                      trailing: Icon(
                        row['is_active'] != false ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        color: row['is_active'] != false ? Colors.green : Colors.red,
                      ),
                    ),
                  ),
            if (data.deliveries.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('تسليم كل جهاز', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...data.deliveries.take(12).map(
                    (row) => ListTile(
                      leading: Icon(
                        row['status'] == 'sent' ? Icons.check_circle_rounded : Icons.sync_problem_rounded,
                        color: row['status'] == 'sent' ? successColor : dangerColor,
                      ),
                      title: Text('${row['provider'] ?? 'قيد الاختيار'} · ${row['status'] ?? 'pending'}'),
                      subtitle: Text(
                        row['last_error']?.toString() ?? 'المحاولات: ${row['attempts'] ?? 0}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
            ],
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
  NotificationDiagnosticsData({required this.tokens, required this.queue, required this.deliveries});

  final List<Map<String, dynamic>> tokens;
  final List<Map<String, dynamic>> queue;
  final List<Map<String, dynamic>> deliveries;
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
      return fromBranch == widget.session.branchNum || toBranch == widget.session.branchNum;
    }).toList();
    return TransferData(branches: branches, employees: employeeById, orders: visible);
  }

  List<Map<String, dynamic>> filteredOrders(List<Map<String, dynamic>> orders) {
    return orders.where((order) {
      final status = order['status'] as String? ?? 'submitted';
      final fromBranch = nullableIntValue(order['from_branch_num']);
      final toBranch = nullableIntValue(order['to_branch_num']);
      final active = !{'received', 'completed', 'cancelled', 'rejected'}.contains(status);
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
            'from_branch_num': result.fromBranch,
            'to_branch_num': result.toBranch,
            'requested_by': widget.session.id,
            'status': 'submitted',
            'requester_note': emptyToNull(result.note),
            'submitted_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('id, order_no')
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
            'طلب مناقلة من ${branchLabel(data.branches, result.fromBranch)} إلى ${branchLabel(data.branches, result.toBranch)}',
        data: {
          'type': 'transfer_created',
          'route': 'transfer',
          'order_id': inserted['id'],
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'order_no': inserted['order_no'] ?? '',
          'from_branch_name': branchLabel(data.branches, result.fromBranch),
          'to_branch_name': branchLabel(data.branches, result.toBranch),
        },
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
    if (status == 'in_delivery' && !await transferItemsReadyForDelivery('${order['id']}')) {
      if (mounted) showSnack(context, 'يجب معالجة جميع البنود وتحديد الكمية المتوفرة قبل بدء التوصيل');
      return;
    }
    setState(() => transferBusy = true);
    try {
      await supabase.from('ansar_transfer_orders').update({
        'status': status,
        'handled_by': widget.session.id,
        if (status == 'approved') 'approved_at': DateTime.now().toUtc().toIso8601String(),
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
        body: '${widget.session.name} حدّث المناقلة رقم ${order['order_no'] ?? '-'} من ${branchLabel(latestTransfers?.branches ?? const <int, BranchOption>{}, intValue(order['from_branch_num']))} إلى ${branchLabel(latestTransfers?.branches ?? const <int, BranchOption>{}, intValue(order['to_branch_num']))}: ${statusLabel(status)}',
        data: {
          'type': 'transfer_updated',
          'route': 'transfer',
          'order_id': order['id'],
          'status': status,
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'order_no': order['order_no'] ?? '',
          'from_branch_name': branchLabel(latestTransfers?.branches ?? const <int, BranchOption>{}, intValue(order['from_branch_num'])),
          'to_branch_name': branchLabel(latestTransfers?.branches ?? const <int, BranchOption>{}, intValue(order['to_branch_num'])),
          'status_label': statusLabel(status),
        },
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
          return const AnsarSkeleton(rows: 6);
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
                child: AnsarPageHeader(
                  title: 'المناقلات',
                  subtitle: '${visibleOrders.length} طلب ضمن العرض الحالي',
                  icon: Icons.swap_horiz_rounded,
                  badge: kIsBetaBuild ? 'تجريبي' : null,
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
                    final status = order['status'] as String? ?? 'submitted';
                    final canHandle = (widget.session.isAdmin || toBranch == widget.session.branchNum) &&
                        !{'received', 'completed', 'cancelled', 'rejected'}.contains(status);
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
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: raisedSurface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: borderColor),
                                ),
                                child: Row(
                                  children: [
                                    BranchLogo(branchName: branchLabel(data.branches, fromBranch), size: 38),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        branchLabel(data.branches, fromBranch),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                                      ),
                                    ),
                                    const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 7),
                                      child: Icon(Icons.arrow_back_rounded, color: brandColor, size: 20),
                                    ),
                                    BranchLogo(branchName: branchLabel(data.branches, toBranch), size: 38),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        branchLabel(data.branches, toBranch),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${requester?.name ?? 'موظف'} · ${formatEventTime(order['created_at'])}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: mutedInk, fontSize: 11),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => openOrderDetails(order, data),
                                    icon: const Icon(Icons.visibility_rounded),
                                    label: const Text('التفاصيل'),
                                  ),
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
      final active = !{'received', 'completed', 'cancelled', 'rejected'}.contains(status);
      if (filter == 'all') return true;
      if (filter == 'active') return active;
      return status == filter;
    }).length;
  }

  Future<void> showStatusFilters(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('حالة المناقلات', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                const Text('اختر الحالة التي تريد عرضها', style: TextStyle(color: mutedInk)),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.62,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: transferStatusTabs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final value = transferStatusTabs[index];
                      final active = value == statusFilter;
                      final color = value == 'all' || value == 'active' ? brandColor : transferStatusColor(value);
                      return ListTile(
                        selected: active,
                        selectedTileColor: color.withValues(alpha: 0.08),
                        leading: Icon(
                          value == 'all' ? Icons.all_inbox_rounded : transferStatusIcon(value),
                          color: color,
                        ),
                        title: Text(transferTabLabel(value), style: const TextStyle(fontWeight: FontWeight.w700)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusPill(label: '${statusCount(value)}', color: color),
                            if (active) ...[
                              const SizedBox(width: 8),
                              Icon(Icons.check_circle_rounded, color: color),
                            ],
                          ],
                        ),
                        onTap: () => Navigator.pop(sheetContext, value),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && selected != statusFilter) onStatusChanged(selected);
  }

  Future<void> showBranchFilters(BuildContext context) async {
    var nextFrom = fromBranchFilter;
    var nextTo = toBranchFilter;
    final branchOptions = branches.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('تصفية المناقلات', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  const Text('حدد فرع الإرسال أو الاستلام', style: TextStyle(color: mutedInk)),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int?>(
                    key: ValueKey('sheet-from-${nextFrom ?? 'all'}'),
                    initialValue: branches.containsKey(nextFrom) ? nextFrom : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'من فرع', prefixIcon: Icon(Icons.call_made_rounded)),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('كل الفروع')),
                      ...branchOptions.map((branch) => DropdownMenuItem<int?>(value: branch.number, child: Text(branch.name))),
                    ],
                    onChanged: (value) => setSheetState(() => nextFrom = value),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int?>(
                    key: ValueKey('sheet-to-${nextTo ?? 'all'}'),
                    initialValue: branches.containsKey(nextTo) ? nextTo : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'إلى فرع', prefixIcon: Icon(Icons.call_received_rounded)),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('كل الفروع')),
                      ...branchOptions.map((branch) => DropdownMenuItem<int?>(value: branch.number, child: Text(branch.name))),
                    ],
                    onChanged: (value) => setSheetState(() => nextTo = value),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      onFromChanged(nextFrom);
                      onToChanged(nextTo);
                    },
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('تطبيق التصفية'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final safeFromFilter = fromBranchFilter != null && branches.containsKey(fromBranchFilter) ? fromBranchFilter : null;
    final safeToFilter = toBranchFilter != null && branches.containsKey(toBranchFilter) ? toBranchFilter : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnsarFilterSummary(
            title: 'حالة المناقلات',
            labels: [
              transferTabLabel(statusFilter),
              '${statusCount(statusFilter)} طلب',
            ],
            onTap: () => showStatusFilters(context),
          ),
          const SizedBox(height: 6),
          AnsarFilterSummary(
            title: 'فروع المناقلة',
            labels: [
              safeFromFilter == null ? 'من كل الفروع' : 'من ${branches[safeFromFilter]?.name}',
              safeToFilter == null ? 'إلى كل الفروع' : 'إلى ${branches[safeToFilter]?.name}',
            ],
            onTap: () => showBranchFilters(context),
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
  bool receiptBusy = false;
  String? itemBusyId;

  bool get canHandle {
    final toBranch = nullableIntValue(widget.order['to_branch_num']);
    return widget.session.isAdmin || toBranch == widget.session.branchNum;
  }

  bool get canEditItems {
    final status = widget.order['status']?.toString() ?? 'submitted';
    return canHandle && !{'in_delivery', 'received', 'completed', 'cancelled', 'rejected'}.contains(status);
  }

  bool get canChangeStatus {
    final status = widget.order['status']?.toString() ?? 'submitted';
    return canHandle && !{'in_delivery', 'received', 'completed', 'cancelled', 'rejected'}.contains(status);
  }

  bool get canReceive {
    final fromBranch = nullableIntValue(widget.order['from_branch_num']);
    return widget.order['status'] == 'in_delivery' && fromBranch == widget.session.branchNum;
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
    if (!canEditItems) return;
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
        body: 'حدّث ${widget.session.name} كتاب ${(item['product'] as Map<String, dynamic>?)?['name'] ?? 'مادة ${item['mat_num']}'} في المناقلة رقم ${widget.order['order_no'] ?? '-'} من ${branchLabel(widget.branches, intValue(widget.order['from_branch_num']))} إلى ${branchLabel(widget.branches, intValue(widget.order['to_branch_num']))}: ${itemStatusLabel(status)}، الكمية ${formatMoneyValue(approved)}',
        data: {
          'type': 'transfer_item_updated',
          'route': 'transfer',
          'order_id': widget.order['id'],
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'item_name': (item['product'] as Map<String, dynamic>?)?['name'] ?? 'مادة ${item['mat_num']}',
          'order_no': widget.order['order_no'] ?? '',
          'from_branch_name': branchLabel(widget.branches, intValue(widget.order['from_branch_num'])),
          'to_branch_name': branchLabel(widget.branches, intValue(widget.order['to_branch_num'])),
          'status_label': itemStatusLabel(status),
          'approved_quantity': approved,
        },
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
    if (!canChangeStatus || statusBusy) return;
    final status = await showDialog<String>(
      context: context,
      builder: (_) => StatusDialog(current: widget.order['status'] as String? ?? 'submitted'),
    );
    if (status == null) return;
    if (status == 'in_delivery' && !await transferItemsReadyForDelivery('${widget.order['id']}')) {
      if (mounted) showSnack(context, 'يجب معالجة جميع البنود وتحديد الكمية المتوفرة قبل بدء التوصيل');
      return;
    }
    final oldStatus = widget.order['status'];
    setState(() => statusBusy = true);
    try {
      await supabase.from('ansar_transfer_orders').update({
        'status': status,
        'handled_by': widget.session.id,
        if (status == 'approved') 'approved_at': DateTime.now().toUtc().toIso8601String(),
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
        body: '${widget.session.name} حدّث المناقلة رقم ${widget.order['order_no'] ?? '-'} من ${branchLabel(widget.branches, intValue(widget.order['from_branch_num']))} إلى ${branchLabel(widget.branches, intValue(widget.order['to_branch_num']))}: ${statusLabel(status)}',
        data: {
          'type': 'transfer_updated',
          'route': 'transfer',
          'order_id': widget.order['id'],
          'status': status,
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'order_no': widget.order['order_no'] ?? '',
          'from_branch_name': branchLabel(widget.branches, intValue(widget.order['from_branch_num'])),
          'to_branch_name': branchLabel(widget.branches, intValue(widget.order['to_branch_num'])),
          'status_label': statusLabel(status),
        },
      ));
      widget.order['status'] = status;
      refreshDetails();
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => statusBusy = false);
    }
  }

  Future<void> confirmReceipt(TransferDetailsData data) async {
    if (!canReceive || receiptBusy) return;
    final result = await Navigator.of(context).push<TransferReceiptResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: TransferReceiptPage(
            order: widget.order,
            items: data.items,
            branches: widget.branches,
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => receiptBusy = true);
    try {
      final response = await confirmReceiptWithFallback(result);
      final responseMap = response is Map ? Map<String, dynamic>.from(response) : const <String, dynamic>{};
      final hasDifference = responseMap['has_difference'] == true;
      widget.order
        ..['status'] = 'received'
        ..['received_by'] = widget.session.id
        ..['received_at'] = DateTime.now().toUtc().toIso8601String()
        ..['has_receipt_discrepancy'] = hasDifference;
      unawaited(enqueueNotification(
        title: 'استلام مناقلة',
        body: hasDifference
            ? 'تم استلام المناقلة رقم ${widget.order['order_no'] ?? '-'} مع وجود فروقات'
            : 'تم استلام المناقلة رقم ${widget.order['order_no'] ?? '-'} بالكامل',
        data: {
          'type': 'transfer_received',
          'route': 'transfer',
          'order_id': widget.order['id'],
          'sender_id': widget.session.id,
          'sender_name': widget.session.name,
          'sender_avatar_url': widget.session.avatarUrl ?? '',
          'has_difference': hasDifference,
        },
      ));
      refreshDetails();
    } catch (error) {
      if (mounted) showSnack(context, transferActionError(error, action: 'تأكيد استلام المناقلة'));
    } finally {
      if (mounted) setState(() => receiptBusy = false);
    }
  }

  Future<dynamic> confirmReceiptWithFallback(TransferReceiptResult result) async {
    try {
      return await supabase.rpc('ansar_confirm_transfer_receipt', params: {
        'p_order_id': '${widget.order['id']}',
        'p_employee_id': widget.session.id,
        'p_items': result.items,
        'p_note': emptyToNull(result.note),
      });
    } catch (rpcError) {
      try {
        return await confirmReceiptDirectly(result);
      } catch (fallbackError) {
        throw Exception(
          '${transferActionError(fallbackError, action: 'تأكيد استلام المناقلة')} '
          'أعد تنفيذ ملف ansar-runtime-repair.sql في Supabase. '
          'السبب الأصلي: ${compactDatabaseError(rpcError)}',
        );
      }
    }
  }

  Future<Map<String, dynamic>> confirmReceiptDirectly(TransferReceiptResult result) async {
    final orderRows = await supabase
        .from('ansar_transfer_orders')
        .select('id, status, from_branch_num')
        .eq('id', widget.order['id'])
        .limit(1);
    if (orderRows.isEmpty) throw Exception('المناقلة غير موجودة');
    final order = Map<String, dynamic>.from(orderRows.first);
    if (order['status'] != 'in_delivery') {
      throw Exception('لا يمكن تأكيد الاستلام قبل بدء التوصيل');
    }
    if (nullableIntValue(order['from_branch_num']) != widget.session.branchNum) {
      throw Exception('تأكيد الاستلام متاح للفرع الطالب فقط');
    }

    final itemRows = await supabase
        .from('ansar_transfer_order_items')
        .select('id, approved_quantity')
        .eq('order_id', widget.order['id']);
    final sentByItem = <String, double>{
      for (final row in itemRows) '${row['id']}': doubleValue(row['approved_quantity']),
    };
    if (sentByItem.length != result.items.length ||
        result.items.any((item) => !sentByItem.containsKey('${item['item_id']}'))) {
      throw Exception('يجب مراجعة جميع بنود المناقلة');
    }

    var hasDifference = false;
    final now = DateTime.now().toUtc().toIso8601String();
    for (final item in result.items) {
      final itemId = '${item['item_id']}';
      final received = doubleValue(item['received_quantity']);
      final damaged = doubleValue(item['damaged_quantity']);
      final sent = sentByItem[itemId] ?? 0;
      if (received < 0 || damaged < 0 || received + damaged > sent) {
        throw Exception('الكميات المستلمة والتالفة لا يجوز أن تتجاوز الكمية المرسلة');
      }
      final note = emptyToNull(item['note']?.toString() ?? '');
      hasDifference = hasDifference || damaged > 0 || received < sent || note != null;
      await supabase.from('ansar_transfer_order_items').update({
        'received_quantity': received,
        'damaged_quantity': damaged,
        'receipt_note': note,
        'received_at': now,
        'received_by': widget.session.id,
      }).eq('id', itemId).eq('order_id', widget.order['id']);
    }

    await supabase.from('ansar_transfer_orders').update({
      'status': 'received',
      'received_at': now,
      'received_by': widget.session.id,
      'receipt_note': emptyToNull(result.note),
      'has_receipt_discrepancy': hasDifference,
    }).eq('id', widget.order['id']).eq('status', 'in_delivery');
    final verifiedRows = await supabase
        .from('ansar_transfer_orders')
        .select('status, received_by')
        .eq('id', widget.order['id'])
        .limit(1);
    if (verifiedRows.isEmpty ||
        verifiedRows.first['status'] != 'received' ||
        '${verifiedRows.first['received_by']}' != widget.session.id) {
      throw Exception('لم تحفظ قاعدة البيانات حالة الاستلام');
    }
    try {
      await supabase.from('ansar_order_events').insert({
        'order_id': widget.order['id'],
        'employee_id': widget.session.id,
        'event_type': 'receipt_confirmed',
        'old_status': 'in_delivery',
        'new_status': 'received',
        'note': hasDifference ? 'تم الاستلام مع ملاحظات' : 'تم الاستلام كاملاً',
      });
    } catch (_) {
      // The receipt is already committed; an older event constraint must not undo it.
    }
    return {'received': true, 'has_difference': hasDifference};
  }

  Future<void> shareInChat() async {
    await Navigator.of(context).push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: ShareTransferToChatPage(
            session: widget.session,
            order: widget.order,
            branches: widget.branches,
          ),
        ),
      ),
    );
  }

  Future<void> shareOnWhatsApp() async {
    final orderId = '${widget.order['id']}';
    final orderNumber = '${widget.order['order_no'] ?? orderId}';
    final from = branchLabel(widget.branches, intValue(widget.order['from_branch_num']));
    final to = branchLabel(widget.branches, intValue(widget.order['to_branch_num']));
    final status = statusLabel(widget.order['status'] as String? ?? 'submitted');
    final publicUrl = 'https://ansar-team.web.app/transfer/${Uri.encodeComponent(orderId)}';
    final message = 'طلب مناقلة رقم $orderNumber\nمن $from إلى $to\nالحالة: $status\n$publicUrl';
    final whatsappUri = Uri.https('wa.me', '/', {'text': message});
    try {
      final opened = await launchUrl(whatsappUri, mode: LaunchMode.externalApplication);
      if (!opened) throw StateError('WhatsApp is unavailable');
    } catch (_) {
      await Share.share(message, subject: 'مناقلة رقم $orderNumber');
    }
  }

  Future<void> sharePdf(TransferDetailsData data) async {
    setState(() => sharingPdf = true);
    try {
      final bytes = await buildTransferPdf(data);
      final rawOrderNumber = '${widget.order['order_no'] ?? widget.order['id']}';
      final safeOrderNumber = rawOrderNumber.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
      final filename = 'ansar-transfer-$safeOrderNumber.pdf';
      try {
        await Share.shareXFiles(
          [XFile.fromData(bytes, mimeType: 'application/pdf')],
          subject: 'طلب مناقلة $rawOrderNumber',
          text: 'تقرير طلب المناقلة رقم $rawOrderNumber',
          fileNameOverrides: [filename],
        );
      } catch (_) {
        await Printing.sharePdf(bytes: bytes, filename: filename);
      }
    } catch (error) {
      if (mounted) showSnack(context, 'تعذر إنشاء ملف المناقلة. ${cleanError(error)}');
    } finally {
      if (mounted) setState(() => sharingPdf = false);
    }
  }

  Future<Uint8List> buildTransferPdf(TransferDetailsData data) async {
    try {
      return await buildRichTransferPdf(data);
    } catch (_) {
      return buildFallbackTransferPdf(data);
    }
  }

  Future<Uint8List> buildRichTransferPdf(TransferDetailsData data) async {
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
    final fromLogo = await loadPdfMemoryImage(branchLogoAsset(fromName));
    final toLogo = await loadPdfMemoryImage(branchLogoAsset(toName));
    final headers = ['#', 'الكتاب', 'الرقم', 'المطلوب', 'المرسل', 'المستلم', 'التالف', 'الحالة', 'الملاحظة'];
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
        item['received_quantity'] == null ? '-' : formatMoneyValue(item['received_quantity']),
        item['damaged_quantity'] == null ? '-' : formatMoneyValue(item['damaged_quantity']),
        status,
        [item['note'], item['receipt_note']]
            .where((value) => value != null && '$value'.isNotEmpty)
            .join(' · '),
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
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
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
                    pw.Text('فريق الأنصار', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
                    pw.Text(
                      'طلب مناقلة من $fromName إلى $toName',
                      style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xff087568)),
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
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xff087568)),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              transferPdfBranchBadge(fromName, fromLogo),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 18),
                child: pw.Column(
                  children: [
                    pw.Text('إلى', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
                    pw.Text('←', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xff087568))),
                  ],
                ),
              ),
              transferPdfBranchBadge(toName, toLogo),
            ],
          ),
          pw.SizedBox(height: 12),
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
          pw.Text('بنود المناقلة', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: rows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
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
              5: pw.FlexColumnWidth(1.1),
              6: pw.FlexColumnWidth(1.0),
              7: pw.FlexColumnWidth(1.5),
              8: pw.FlexColumnWidth(2.2),
            },
          ),
          if (data.events.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text('سجل المعالجة', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['التحديث', 'نفذه', 'الوقت'],
              data: eventRows,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
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

  Future<Uint8List> buildFallbackTransferPdf(TransferDetailsData data) async {
    final fontBytes = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
    final font = pw.Font.ttf(fontBytes);
    final document = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: font));
    final fromName = branchLabel(widget.branches, intValue(widget.order['from_branch_num']));
    final toName = branchLabel(widget.branches, intValue(widget.order['to_branch_num']));
    final itemChunks = chunkList(data.items, 11);
    final eventChunks = chunkList(data.events, 13);

    if (itemChunks.isEmpty) itemChunks.add(<Map<String, dynamic>>[]);
    for (var pageIndex = 0; pageIndex < itemChunks.length; pageIndex++) {
      final chunk = itemChunks[pageIndex];
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          textDirection: pw.TextDirection.rtl,
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                'طلب مناقلة من $fromName إلى $toName',
                style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 5),
              pw.Text(
                'رقم الطلب: ${widget.order['order_no'] ?? '-'}   |   الحالة: ${statusLabel(widget.order['status'] as String? ?? 'submitted')}   |   صفحة ${pageIndex + 1}/${itemChunks.length}',
                style: const pw.TextStyle(fontSize: 11),
              ),
              pw.SizedBox(height: 12),
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: const {
                  0: pw.FixedColumnWidth(28),
                  1: pw.FlexColumnWidth(3.2),
                  2: pw.FlexColumnWidth(1.1),
                  3: pw.FlexColumnWidth(1.1),
                  4: pw.FlexColumnWidth(1.1),
                  5: pw.FlexColumnWidth(1.1),
                  6: pw.FlexColumnWidth(1.0),
                  7: pw.FlexColumnWidth(1.6),
                  8: pw.FlexColumnWidth(2.1),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff087568)),
                    children: ['#', 'الكتاب', 'الرقم', 'المطلوب', 'المرسل', 'المستلم', 'التالف', 'الحالة', 'الملاحظة']
                        .map((text) => fallbackPdfCell(text, header: true))
                        .toList(),
                  ),
                  for (var i = 0; i < chunk.length; i++)
                    pw.TableRow(
                      decoration: i.isOdd ? const pw.BoxDecoration(color: PdfColor.fromInt(0xfff4f8f7)) : null,
                      children: fallbackItemCells(chunk[i], pageIndex * 11 + i + 1)
                          .map((text) => fallbackPdfCell(text))
                          .toList(),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    for (var pageIndex = 0; pageIndex < eventChunks.length; pageIndex++) {
      final chunk = eventChunks[pageIndex];
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          textDirection: pw.TextDirection.rtl,
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text('سجل معالجة المناقلة', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 12),
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                columnWidths: const {
                  0: pw.FlexColumnWidth(4),
                  1: pw.FlexColumnWidth(2),
                  2: pw.FlexColumnWidth(1.6),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xff344f49)),
                    children: ['التحديث', 'نفذه', 'الوقت']
                        .map((text) => fallbackPdfCell(text, header: true))
                        .toList(),
                  ),
                  for (var i = 0; i < chunk.length; i++)
                    pw.TableRow(
                      decoration: i.isOdd ? const pw.BoxDecoration(color: PdfColor.fromInt(0xfff4f8f7)) : null,
                      children: [
                        eventLabel(chunk[i]),
                        data.employees['${chunk[i]['employee_id']}']?.name ?? 'موظف',
                        formatEventTime(chunk[i]['created_at']),
                      ].map((text) => fallbackPdfCell(shortPdfText(text, 90))).toList(),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return document.save();
  }

  List<String> fallbackItemCells(Map<String, dynamic> item, int index) {
    final product = item['product'] as Map<String, dynamic>?;
    return [
      '$index',
      shortPdfText(product?['name']?.toString() ?? 'مادة ${item['mat_num']}', 70),
      '${item['mat_num'] ?? '-'}',
      formatMoneyValue(item['requested_quantity']),
      item['approved_quantity'] == null ? '-' : formatMoneyValue(item['approved_quantity']),
      item['received_quantity'] == null ? '-' : formatMoneyValue(item['received_quantity']),
      item['damaged_quantity'] == null ? '-' : formatMoneyValue(item['damaged_quantity']),
      itemStatusLabel(item['item_status'] as String? ?? 'requested'),
      shortPdfText(
        [item['note'], item['receipt_note']]
            .where((value) => value != null && '$value'.isNotEmpty)
            .join(' · '),
        55,
      ),
    ];
  }

  pw.Widget fallbackPdfCell(String text, {bool header = false}) {
    return pw.Container(
      height: 30,
      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        text,
        maxLines: 2,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: header ? PdfColors.white : PdfColors.black,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fromBranch = intValue(widget.order['from_branch_num']);
    final toBranch = intValue(widget.order['to_branch_num']);
    return Scaffold(
      appBar: AppBar(
        title: Text('مناقلة ${widget.order['order_no'] ?? ''}'),
        actions: [
          if (canChangeStatus)
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
            return const AnsarSkeleton(rows: 6);
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
                          if (widget.order['status'] == 'received')
                            StatusPill(
                              label: widget.order['has_receipt_discrepancy'] == true
                                  ? 'تم الاستلام مع ملاحظات'
                                  : 'تم الاستلام كاملاً',
                              color: widget.order['has_receipt_discrepancy'] == true ? accentColor : successColor,
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TransferStatusProgress(currentStatus: widget.order['status'] as String? ?? 'submitted'),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: sharingPdf ? null : () => sharePdf(details),
                        icon: sharingPdf
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.picture_as_pdf_rounded),
                        label: const Text('مشاركة PDF'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: shareInChat,
                        icon: const Icon(Icons.forum_outlined),
                        label: const Text('مشاركة في الدردشة'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: shareOnWhatsApp,
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('مشاركة عبر واتساب'),
                      ),
                      if (fromBranch == widget.session.branchNum && widget.order['status'] == 'preparing') ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: warningSurface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.local_shipping_outlined, color: accentColor),
                              SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  'الطلب قيد التحضير. سيظهر زر مراجعة الاستلام بعد أن يغيّر الفرع المجهّز حالته إلى قيد التوصيل.',
                                  style: TextStyle(fontWeight: FontWeight.w700, height: 1.45),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (canReceive) ...[
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: successColor),
                          onPressed: receiptBusy ? null : () => confirmReceipt(details),
                          icon: receiptBusy
                              ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.inventory_rounded),
                          label: const Text('مراجعة الاستلام'),
                        ),
                      ],
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
                              if (item['received_quantity'] != null)
                                Chip(label: Text('المستلم ${formatMoneyValue(item['received_quantity'])}')),
                              if (item['damaged_quantity'] != null && doubleValue(item['damaged_quantity']) > 0)
                                Chip(label: Text('التالف ${formatMoneyValue(item['damaged_quantity'])}')),
                              Chip(
                                avatar: Icon(transferStatusIcon(status), size: 16),
                                label: Text(itemStatusLabel(status)),
                              ),
                            ],
                          ),
                          if (item['note'] != null) Text('ملاحظة: ${item['note']}'),
                          if (item['receipt_note'] != null) Text('ملاحظة الاستلام: ${item['receipt_note']}'),
                          if (canEditItems) ...[
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

class TransferStatusProgress extends StatelessWidget {
  const TransferStatusProgress({super.key, required this.currentStatus});

  final String currentStatus;

  @override
  Widget build(BuildContext context) {
    const statuses = ['submitted', 'approved', 'preparing', 'in_delivery', 'received'];
    final terminalError = {'cancelled', 'rejected'}.contains(currentStatus);
    final currentIndex = statuses.indexOf(currentStatus);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('مسار المناقلة', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
            const Spacer(),
            Text(statusLabel(currentStatus), style: TextStyle(color: transferStatusColor(currentStatus), fontSize: 11, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var index = 0; index < statuses.length; index++) ...[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: terminalError
                      ? (index == 0 ? dangerColor : borderColor)
                      : index <= currentIndex
                          ? transferStatusColor(currentStatus)
                          : borderColor,
                  shape: BoxShape.circle,
                ),
              ),
              if (index != statuses.length - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: !terminalError && index < currentIndex ? transferStatusColor(currentStatus) : borderColor,
                  ),
                ),
            ],
          ],
        ),
        const SizedBox(height: 7),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('الطلب', style: TextStyle(color: mutedInk, fontSize: 9)),
            Text('الموافقة', style: TextStyle(color: mutedInk, fontSize: 9)),
            Text('التحضير', style: TextStyle(color: mutedInk, fontSize: 9)),
            Text('التوصيل', style: TextStyle(color: mutedInk, fontSize: 9)),
            Text('الاستلام', style: TextStyle(color: mutedInk, fontSize: 9)),
          ],
        ),
      ],
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
  CreateTransferResult({required this.fromBranch, required this.toBranch, required this.note, required this.items});

  final int fromBranch;
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
  int? fromBranch;
  int? toBranch;
  int currentStep = 0;

  @override
  void initState() {
    super.initState();
    fromBranch = widget.session.isGeneralAdmin ? null : widget.session.assignedBranchNum;
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
      final count = await ProductSearchCache.instance.productCount;
      if (mounted) {
        setState(() {
          productsCount = count;
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
      bookSearch.text = product['name']?.toString() ?? '${product['mat_num']}';
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
        name: product['name']?.toString() ?? 'كتاب $parsedMat',
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
    final canSubmit = fromBranch != null && toBranch != null && items.isNotEmpty;
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
          const AnsarPageHeader(
            title: 'طلب مناقلة جديد',
            subtitle: 'ثلاث خطوات واضحة قبل إرسال الطلب',
            icon: Icons.playlist_add_rounded,
          ),
          TransferStepHeader(step: currentStep),
          const SizedBox(height: 16),
          if (currentStep == 0) ...[
            Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.session.isGeneralAdmin) ...[
                    DropdownButtonFormField<int>(
                      initialValue: fromBranch,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'الفرع الطالب',
                        prefixIcon: Icon(Icons.outbox_rounded),
                      ),
                      items: widget.branches.values
                          .map((branch) => DropdownMenuItem(value: branch.number, child: Text(branch.label)))
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          fromBranch = value;
                          if (toBranch == value) toBranch = null;
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                  ] else
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'الفرع الطالب',
                        prefixIcon: Icon(Icons.outbox_rounded),
                      ),
                      child: Text(
                        fromBranch == null ? 'لا يوجد فرع مرتبط بالحساب' : branchLabel(widget.branches, fromBranch!),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  if (!widget.session.isGeneralAdmin) const SizedBox(height: 10),
                  DropdownButtonFormField<int>(
                    initialValue: toBranch,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'الفرع المطلوب منه',
                      prefixIcon: Icon(Icons.storefront_rounded),
                    ),
                    items: widget.branches.values
                        .where((branch) => branch.number != fromBranch)
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
          ],
          if (currentStep == 1) ...[
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
                            title: Text(product['name']?.toString() ?? 'بدون اسم'),
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
          if (currentStep == 2)
            TransferDraftReview(
              session: widget.session,
              branches: widget.branches,
              fromBranch: fromBranch,
              toBranch: toBranch,
              note: note.text.trim(),
              items: items,
            ),
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
                  onPressed: () {
                    if (currentStep == 0) {
                      Navigator.pop(context);
                    } else {
                      setState(() => currentStep--);
                    }
                  },
                  child: Text(currentStep == 0 ? 'إلغاء' : 'السابق'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: currentStep == 0
                      ? (fromBranch == null || toBranch == null ? null : () => setState(() => currentStep = 1))
                      : currentStep == 1
                          ? (items.isEmpty ? null : () => setState(() => currentStep = 2))
                          : canSubmit
                              ? () => Navigator.pop(
                                    context,
                                    CreateTransferResult(
                                      fromBranch: fromBranch!,
                                      toBranch: toBranch!,
                                      note: note.text.trim(),
                                      items: items,
                                    ),
                                  )
                              : null,
                  icon: Icon(currentStep == 2 ? Icons.send_rounded : Icons.arrow_back_rounded),
                  label: Text(currentStep == 2 ? 'إرسال الطلب' : 'متابعة'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TransferStepHeader extends StatelessWidget {
  const TransferStepHeader({super.key, required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    const labels = ['الفروع', 'البنود', 'المراجعة'];
    const icons = [Icons.storefront_rounded, Icons.menu_book_rounded, Icons.fact_check_outlined];
    return Row(
      children: [
        for (var index = 0; index < labels.length; index++) ...[
          Expanded(
            child: Column(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: index <= step ? brandColor : panelSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: index <= step ? brandColor : borderColor),
                  ),
                  child: Icon(icons[index], color: index <= step ? Colors.white : mutedInk, size: 20),
                ),
                const SizedBox(height: 5),
                Text(
                  labels[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: index <= step ? brandColor : mutedInk,
                    fontSize: 11,
                    fontWeight: index == step ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (index != labels.length - 1)
            SizedBox(
              width: 14,
              child: Divider(color: index < step ? brandColor : borderColor, thickness: 2),
            ),
        ],
      ],
    );
  }
}

class TransferDraftReview extends StatelessWidget {
  const TransferDraftReview({
    super.key,
    required this.session,
    required this.branches,
    required this.fromBranch,
    required this.toBranch,
    required this.note,
    required this.items,
  });

  final EmployeeSession session;
  final Map<int, BranchOption> branches;
  final int? fromBranch;
  final int? toBranch;
  final String note;
  final List<TransferItemDraft> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'مراجعة الطلب'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    BranchLogo(branchName: branchLabel(branches, fromBranch ?? 0), size: 42),
                    const SizedBox(width: 8),
                    Expanded(child: Text(branchLabel(branches, fromBranch ?? 0), style: const TextStyle(fontWeight: FontWeight.w800))),
                    const Icon(Icons.arrow_back_rounded, color: brandColor),
                    const SizedBox(width: 8),
                    BranchLogo(branchName: branchLabel(branches, toBranch ?? 0), size: 42),
                    const SizedBox(width: 8),
                    Expanded(child: Text(branchLabel(branches, toBranch ?? 0), style: const TextStyle(fontWeight: FontWeight.w800))),
                  ],
                ),
                if (note.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(note, style: const TextStyle(color: mutedInk)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        SectionHeader(title: 'بنود الطلب (${items.length})'),
        ...items.map(
          (item) => Card(
            child: ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: successSurface, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.menu_book_rounded, color: brandColor),
              ),
              title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text('رقم ${item.matNum}${item.note.isEmpty ? '' : ' · ${item.note}'}'),
              trailing: StatusPill(label: formatMoneyValue(item.quantity), color: brandColor),
            ),
          ),
        ),
        const AnsarInlineNotice(message: 'راجع الفرع والبنود جيداً. سيتم إنشاء الطلب الحقيقي عند الضغط على إرسال.'),
      ],
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
    final statuses = [widget.current, ...transferAllowedNextStatuses(widget.current)];
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
        FilledButton(
          onPressed: status == widget.current ? null : () => Navigator.pop(context, status),
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

class TransferReceiptResult {
  const TransferReceiptResult({required this.items, required this.note});

  final List<Map<String, Object?>> items;
  final String note;
}

class TransferReceiptDraft {
  TransferReceiptDraft(Map<String, dynamic> item)
      : item = item,
        received = TextEditingController(text: formatMoneyValue(item['approved_quantity'] ?? 0)),
        damaged = TextEditingController(text: '0'),
        note = TextEditingController();

  final Map<String, dynamic> item;
  final TextEditingController received;
  final TextEditingController damaged;
  final TextEditingController note;

  double get sentQuantity => doubleValue(item['approved_quantity']);
  double get receivedQuantity => double.tryParse(received.text.trim().replaceAll(',', '.')) ?? -1;
  double get damagedQuantity => double.tryParse(damaged.text.trim().replaceAll(',', '.')) ?? -1;
  bool get valid => receivedQuantity >= 0 && damagedQuantity >= 0 && receivedQuantity + damagedQuantity <= sentQuantity;
  bool get hasDifference => damagedQuantity > 0 || receivedQuantity < sentQuantity || note.text.trim().isNotEmpty;

  void dispose() {
    received.dispose();
    damaged.dispose();
    note.dispose();
  }
}

class TransferReceiptPage extends StatefulWidget {
  const TransferReceiptPage({
    super.key,
    required this.order,
    required this.items,
    required this.branches,
  });

  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> items;
  final Map<int, BranchOption> branches;

  @override
  State<TransferReceiptPage> createState() => _TransferReceiptPageState();
}

class _TransferReceiptPageState extends State<TransferReceiptPage> {
  final generalNote = TextEditingController();
  late final List<TransferReceiptDraft> drafts = widget.items.map(TransferReceiptDraft.new).toList();

  @override
  void dispose() {
    generalNote.dispose();
    for (final draft in drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  bool get valid => drafts.isNotEmpty && drafts.every((draft) => draft.valid);
  bool get hasDifference => drafts.any((draft) => draft.hasDifference);

  void submit() {
    if (!valid) return;
    Navigator.pop(
      context,
      TransferReceiptResult(
        note: generalNote.text.trim(),
        items: drafts
            .map((draft) => <String, Object?>{
                  'item_id': '${draft.item['id']}',
                  'received_quantity': draft.receivedQuantity,
                  'damaged_quantity': draft.damagedQuantity,
                  'note': draft.note.text.trim(),
                })
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final from = branchLabel(widget.branches, intValue(widget.order['from_branch_num']));
    final to = branchLabel(widget.branches, intValue(widget.order['to_branch_num']));
    return Scaffold(
      appBar: AppBar(title: const Text('مراجعة الاستلام')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
        children: [
          PageHeading(
            title: 'استلام مناقلة ${widget.order['order_no'] ?? ''}',
            subtitle: 'من $to إلى $from · راجع كل بند قبل التأكيد',
            icon: Icons.inventory_rounded,
          ),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: warningSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accentColor.withValues(alpha: 0.35)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: accentColor),
                SizedBox(width: 9),
                Expanded(child: Text('أدخل الكمية السليمة والتالفة. لا يجوز أن يتجاوز مجموعهما الكمية المرسلة.')),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < drafts.length; index++) ...[
            Builder(builder: (context) {
              final draft = drafts[index];
              final product = draft.item['product'] as Map<String, dynamic>?;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: successSurface,
                            child: Text('${index + 1}', style: const TextStyle(color: brandColor, fontWeight: FontWeight.w900)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              product?['name']?.toString() ?? 'مادة ${draft.item['mat_num']}',
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                          StatusPill(label: 'المرسل ${formatMoneyValue(draft.sentQuantity)}', color: infoColor),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: draft.received,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(labelText: 'المستلم السليم', prefixIcon: Icon(Icons.check_circle_outline_rounded)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: draft.damaged,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(labelText: 'التالف', prefixIcon: Icon(Icons.warning_amber_rounded)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: draft.note,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: 'ملاحظة البند (اختيارية)', prefixIcon: Icon(Icons.notes_rounded)),
                      ),
                      if (!draft.valid) ...[
                        const SizedBox(height: 7),
                        const Text('راجع الكميات: المجموع أكبر من المرسل أو توجد قيمة غير صحيحة.', style: TextStyle(color: dangerColor, fontSize: 12, fontWeight: FontWeight.w700)),
                      ],
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: generalNote,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'ملاحظة عامة على الاستلام (اختيارية)', prefixIcon: Icon(Icons.description_outlined)),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(color: panelSurface, border: Border(top: BorderSide(color: borderColor))),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: hasDifference ? accentColor : successColor),
            onPressed: valid ? submit : null,
            icon: Icon(hasDifference ? Icons.rule_rounded : Icons.inventory_rounded),
            label: Text(hasDifference ? 'تأكيد الاستلام مع ملاحظات' : 'تأكيد الاستلام كاملاً'),
          ),
        ),
      ),
    );
  }
}

class ShareTransferToChatPage extends StatefulWidget {
  const ShareTransferToChatPage({
    super.key,
    required this.session,
    required this.order,
    required this.branches,
  });

  final EmployeeSession session;
  final Map<String, dynamic> order;
  final Map<int, BranchOption> branches;

  @override
  State<ShareTransferToChatPage> createState() => _ShareTransferToChatPageState();
}

class _ShareTransferToChatPageState extends State<ShareTransferToChatPage> {
  final search = TextEditingController();
  final selected = <String>{};
  late final Future<List<Map<String, dynamic>>> future = loadVisibleChatThreads(widget.session);
  bool sending = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (selected.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final from = branchLabel(widget.branches, intValue(widget.order['from_branch_num']));
      final to = branchLabel(widget.branches, intValue(widget.order['to_branch_num']));
      final body = 'مناقلة رقم ${widget.order['order_no'] ?? '-'} · من $from إلى $to';
      var sharedAtomically = false;
      try {
        await supabase.rpc('ansar_share_transfer_to_chat', params: {
          'p_order_id': '${widget.order['id']}',
          'p_thread_ids': selected.toList(),
          'p_sender_id': widget.session.id,
        });
        sharedAtomically = true;
        unawaited(kickNotificationSender());
      } catch (rpcError) {
        try {
          await supabase.from('ansar_chat_messages').insert(
                selected
                    .map((threadId) => {
                          'thread_id': threadId,
                          'sender_id': widget.session.id,
                          'body': body,
                          'message_type': 'transfer',
                          'transfer_order_id': '${widget.order['id']}',
                        })
                    .toList(),
              );
        } catch (fallbackError) {
          throw Exception(
            '${transferActionError(fallbackError, action: 'مشاركة المناقلة')} '
            'أعد تنفيذ ملف ansar-runtime-repair.sql في Supabase. '
            'السبب الأصلي: ${compactDatabaseError(rpcError)}',
          );
        }
      }
      final threads = await loadVisibleChatThreads(widget.session);
      final now = DateTime.now().toUtc().toIso8601String();
      for (final threadId in selected) {
        unawaited(supabase.from('ansar_chat_threads').update({'updated_at': now}).eq('id', threadId));
        Map<String, dynamic>? thread;
        for (final item in threads) {
          if ('${item['id']}' == threadId) {
            thread = item;
            break;
          }
        }
        if (!sharedAtomically && thread != null) {
          unawaited(enqueueChatNotification(thread: thread, sender: widget.session, body: body));
        }
      }
      if (mounted) Navigator.pop(context, selected.length);
    } catch (error) {
      if (mounted) showSnack(context, transferActionError(error, action: 'مشاركة المناقلة'));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مشاركة المناقلة')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: () {});
          final query = normalizeSearch(search.text);
          final threads = snapshot.data!
              .where((thread) => query.isEmpty || normalizeSearch(thread['title']?.toString() ?? '').contains(query))
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: 'ابحث عن محادثة أو مجموعة', prefixIcon: Icon(Icons.search_rounded)),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                  itemCount: threads.length,
                  separatorBuilder: (_, __) => const Divider(indent: 64),
                  itemBuilder: (context, index) {
                    final thread = threads[index];
                    final id = '${thread['id']}';
                    final active = selected.contains(id);
                    return ListTile(
                      onTap: () => setState(() => active ? selected.remove(id) : selected.add(id)),
                      leading: CircleAvatar(
                        backgroundColor: successSurface,
                        child: Icon(thread['thread_type'] == 'group' ? Icons.groups_rounded : Icons.chat_rounded, color: brandColor),
                      ),
                      title: Text(thread['title']?.toString() ?? 'محادثة', style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(chatTypeLabel(thread['thread_type']?.toString() ?? 'general')),
                      trailing: Icon(active ? Icons.check_circle_rounded : Icons.circle_outlined, color: active ? brandColor : mutedInk),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: FilledButton.icon(
            onPressed: selected.isEmpty || sending ? null : submit,
            icon: sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded),
            label: Text(selected.isEmpty ? 'اختر محادثة' : 'مشاركة في ${selected.length}'),
          ),
        ),
      ),
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
  final threadSearch = TextEditingController();
  late Future<List<Map<String, dynamic>>> future;
  List<Map<String, dynamic>>? latestThreads;
  RealtimeChannel? threadsChannel;
  Timer? threadsTimer;
  bool threadBusy = false;
  bool showArchived = false;

  @override
  void initState() {
    super.initState();
    future = loadAndRememberThreads();
    threadsChannel = supabase.channel('chat-list-${widget.session.id}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_threads',
        callback: (_) => refreshThreads(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_messages',
        callback: (_) => refreshThreads(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_employees',
        callback: (_) => refreshThreads(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_participants',
        callback: (_) => refreshThreads(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'ansar_chat_message_receipts',
        callback: (_) => refreshThreads(),
      ).subscribe();
    threadsTimer = Timer.periodic(const Duration(seconds: 5), (_) => refreshThreads());
  }

  @override
  void dispose() {
    threadsTimer?.cancel();
    if (threadsChannel != null) supabase.removeChannel(threadsChannel!);
    threadSearch.dispose();
    super.dispose();
  }

  void refreshThreads() {
    if (!mounted) return;
    setState(() => future = loadAndRememberThreads());
  }

  Future<List<Map<String, dynamic>>> loadAndRememberThreads() async {
    final loaded = await loadThreads();
    latestThreads = loaded;
    return loaded;
  }

  Future<List<Map<String, dynamic>>> loadThreads() async {
    final threadRowsFuture = supabase
        .from('ansar_chat_threads')
        .select()
        .eq('is_active', true)
        .order('updated_at', ascending: false);
    final joinedParticipantsFuture = supabase
        .from('ansar_chat_participants')
        .select('thread_id, role, is_pinned, is_muted, muted_until, is_archived, last_read_at')
        .eq('employee_id', widget.session.id);
    final employeesFuture = loadAllActiveEmployees();
    final rows = (await threadRowsFuture).cast<Map<String, dynamic>>();
    final joinedParticipants = (await joinedParticipantsFuture).cast<Map<String, dynamic>>();
    final activeEmployees = await employeesFuture;
    final joinedThreadIds = joinedParticipants.map((row) => row['thread_id']).toSet();
    final settingsByThread = {
      for (final row in joinedParticipants) '${row['thread_id']}': row,
    };

    final visible = rows.where((row) {
      final type = row['thread_type'] as String? ?? 'general';
      if (type == 'general') return true;
      return joinedThreadIds.contains(row['id']);
    }).toList();
    final threadIds = visible.map((row) => row['id']).whereType<String>().toList();
    final unreadByThread = threadIds.isEmpty ? <String, int>{} : await loadChatUnreadCounts(widget.session.id);
    final participantRows = threadIds.isEmpty
        ? <Map<String, dynamic>>[]
        : (await supabase
                .from('ansar_chat_participants')
                .select('thread_id, employee_id')
                .inFilter('thread_id', threadIds))
            .cast<Map<String, dynamic>>();
    final rawMessageRows = threadIds.isEmpty
        ? <Map<String, dynamic>>[]
        : (await supabase
                .from('ansar_chat_messages')
                .select('id, thread_id, sender_id, body, created_at')
                .inFilter('thread_id', threadIds)
                .isFilter('deleted_at', null)
                .order('created_at', ascending: false)
                .limit(250))
            .cast<Map<String, dynamic>>();
    var hiddenMessageIds = <String>{};
    if (rawMessageRows.isNotEmpty) {
      try {
        final hiddenRows = await supabase
            .from('ansar_chat_message_hidden')
            .select('message_id')
            .eq('employee_id', widget.session.id)
            .inFilter('message_id', rawMessageRows.map((row) => '${row['id']}').toList());
        hiddenMessageIds = hiddenRows.map((row) => '${row['message_id']}').toSet();
      } catch (_) {
        // The list remains usable before the optional per-user deletion migration is installed.
      }
    }
    final messageRows = rawMessageRows.where((row) => !hiddenMessageIds.contains('${row['id']}')).toList();
    final employees = {for (final employee in activeEmployees) employee.id: employee};
    final latestByThread = <String, Map<String, dynamic>>{};
    for (final row in messageRows) {
      final threadId = row['thread_id']?.toString();
      if (threadId != null) latestByThread.putIfAbsent(threadId, () => row);
    }
    final participantsByThread = <String, List<String>>{};
    for (final row in participantRows) {
      final threadId = row['thread_id']?.toString();
      final employeeId = row['employee_id']?.toString();
      if (threadId != null && employeeId != null) {
        participantsByThread.putIfAbsent(threadId, () => <String>[]).add(employeeId);
      }
    }
    final representedDirectEmployees = <String>{};
    final enrichedThreads = visible.map((thread) {
      final threadId = thread['id']?.toString() ?? '';
      final latest = latestByThread[threadId];
      final otherIds = participantsByThread[threadId]
              ?.where((employeeId) => employeeId != widget.session.id)
              .toList() ??
          <String>[];
      final otherId = otherIds.isEmpty ? null : otherIds.first;
      final otherEmployee = otherId == null ? null : employees[otherId];
      final sender = latest == null ? null : employees[latest['sender_id']];
      if (thread['thread_type'] == 'direct' && otherId != null) representedDirectEmployees.add(otherId);
      return {
        ...thread,
        ...?settingsByThread[threadId],
        'is_muted': settingsByThread[threadId] == null ? false : chatParticipantIsMuted(settingsByThread[threadId]!),
        if (thread['thread_type'] == 'direct' && otherEmployee != null) 'title': otherEmployee.name,
        'last_message': latest,
        'last_sender_name': sender?.name,
        'thread_avatar_url': otherEmployee?.avatarUrl,
        'thread_avatar_name': otherEmployee?.name,
        'participant_ids': participantsByThread[threadId] ?? <String>[],
        'unread_count': unreadByThread[threadId] ?? 0,
      };
    }).toList();
    final contactThreads = activeEmployees
        .where((employee) => employee.id != widget.session.id && !representedDirectEmployees.contains(employee.id))
        .map<Map<String, dynamic>>((employee) => {
              'id': 'contact:${employee.id}',
              'thread_type': 'contact',
              'title': employee.name,
              'thread_avatar_url': employee.avatarUrl,
              'thread_avatar_name': employee.name,
              'participant_ids': [widget.session.id, employee.id],
              'contact_employee': employee,
            })
        .toList()
      ..sort((a, b) => normalizeSearch('${a['title']}').compareTo(normalizeSearch('${b['title']}')));
    enrichedThreads.sort((a, b) {
      final pinnedCompare = (b['is_pinned'] == true ? 1 : 0).compareTo(a['is_pinned'] == true ? 1 : 0);
      if (pinnedCompare != 0) return pinnedCompare;
      final aTime = DateTime.tryParse(a['updated_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = DateTime.tryParse(b['updated_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return [...enrichedThreads, ...contactThreads];
  }

  Future<void> updateThreadPreference(Map<String, dynamic> thread, Map<String, Object?> values) async {
    if (thread['thread_type'] == 'contact') return;
    try {
      await supabase.from('ansar_chat_participants').upsert({
        'thread_id': thread['id'],
        'employee_id': widget.session.id,
        'role': thread['role']?.toString() ?? 'member',
        ...values,
      }, onConflict: 'thread_id,employee_id');
      thread.addAll(values);
      refreshThreads();
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    }
  }

  Future<void> showThreadActions(Map<String, dynamic> thread) async {
    if (thread['thread_type'] == 'contact') return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(thread['is_pinned'] == true ? Icons.push_pin_rounded : Icons.push_pin_outlined, color: brandColor),
              title: Text(thread['is_pinned'] == true ? 'إلغاء التثبيت' : 'تثبيت المحادثة'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(updateThreadPreference(thread, {'is_pinned': thread['is_pinned'] != true}));
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined, color: accentColor),
              title: const Text('كتم الإشعارات'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(showMuteOptions(thread));
              },
            ),
            ListTile(
              leading: Icon(thread['is_archived'] == true ? Icons.unarchive_rounded : Icons.archive_outlined, color: infoColor),
              title: Text(thread['is_archived'] == true ? 'إلغاء الأرشفة' : 'أرشفة المحادثة'),
              onTap: () {
                Navigator.pop(sheetContext);
                final archived = thread['is_archived'] != true;
                unawaited(updateThreadPreference(thread, {
                  'is_archived': archived,
                  'archived_at': archived ? DateTime.now().toUtc().toIso8601String() : null,
                }));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> showMuteOptions(Map<String, dynamic> thread) async {
    final option = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('مدة كتم الإشعارات', style: TextStyle(fontWeight: FontWeight.w900))),
            ListTile(title: const Text('8 ساعات'), onTap: () => Navigator.pop(sheetContext, '8h')),
            ListTile(title: const Text('أسبوع'), onTap: () => Navigator.pop(sheetContext, '1w')),
            ListTile(title: const Text('دائماً'), onTap: () => Navigator.pop(sheetContext, 'forever')),
            ListTile(title: const Text('إلغاء الكتم'), onTap: () => Navigator.pop(sheetContext, 'off')),
          ],
        ),
      ),
    );
    if (option == null) return;
    final now = DateTime.now().toUtc();
    final mutedUntil = option == '8h'
        ? now.add(const Duration(hours: 8)).toIso8601String()
        : option == '1w'
            ? now.add(const Duration(days: 7)).toIso8601String()
            : option == 'forever'
                ? DateTime.utc(9999, 12, 31).toIso8601String()
                : null;
    await updateThreadPreference(thread, {'is_muted': option != 'off', 'muted_until': mutedUntil});
  }

  Future<void> openThread(Map<String, dynamic> thread) async {
    if (thread['thread_type'] == 'contact') {
      final employee = thread['contact_employee'];
      if (employee is EmployeeLite) {
        await openOrCreateDirectChat(context, widget.session, employee);
        if (mounted) refreshThreads();
      }
      return;
    }
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
        future = loadAndRememberThreads();
      });
    }
  }

  Future<void> createThread() async {
    final employees = await loadAllActiveEmployees();
    final branches = await loadAppBranchesMap();
    if (!mounted) return;
    final result = await Navigator.of(context).push<CreateThreadResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: CreateThreadPage(
            session: widget.session,
            employees: employees,
            branches: branches,
            groupOnly: true,
          ),
        ),
      ),
    );
    if (result == null) return;

    if (!result.isGroup && result.employeeIds.length == 1) {
      final wanted = {widget.session.id, result.employeeIds.single};
      for (final thread in latestThreads ?? <Map<String, dynamic>>[]) {
        final participants = (thread['participant_ids'] as List?)?.map((value) => '$value').toSet() ?? <String>{};
        if (thread['thread_type'] == 'direct' && participants.length == wanted.length && participants.containsAll(wanted)) {
          await openThread(thread);
          return;
        }
      }
    }

    setState(() => threadBusy = true);
    try {
      final inserted = await supabase
          .from('ansar_chat_threads')
          .insert({
            'title': result.title,
            'thread_type': result.isGroup ? 'group' : 'direct',
            'created_by': widget.session.id,
          })
          .select('id')
          .single();
      final threadId = inserted['id'];
      final participantIds = {widget.session.id, ...result.employeeIds};
      try {
        await supabase.from('ansar_chat_participants').insert(
              participantIds
                  .map((employeeId) => {
                        'thread_id': threadId,
                        'employee_id': employeeId,
                        'role': employeeId == widget.session.id ? 'admin' : 'member',
                      })
                  .toList(),
            );
      } catch (_) {
        try {
          await supabase.from('ansar_chat_threads').delete().eq('id', threadId);
        } catch (_) {
          // Keep the original participant error if cleanup is unavailable.
        }
        rethrow;
      }
      if (mounted) {
        final createdThread = <String, dynamic>{
          ...inserted,
          'title': result.title,
          'thread_type': result.isGroup ? 'group' : 'direct',
          'participant_ids': participantIds.toList(),
        };
        await openThread(createdThread);
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
      initialData: latestThreads,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: () => setState(() {
              future = loadAndRememberThreads();
            }),
          );
        }
        final threads = snapshot.data!;
        final query = normalizeSearch(threadSearch.text);
        final visibleThreads = query.isEmpty
            ? threads
            : threads.where((thread) {
                final title = normalizeSearch(thread['title']?.toString() ?? '');
                final latest = thread['last_message'] as Map<String, dynamic>?;
                final body = normalizeSearch(latest?['body']?.toString() ?? '');
                return title.contains(query) || body.contains(query);
              }).toList();
        final filteredThreads = visibleThreads.where((thread) {
          if (thread['thread_type'] == 'contact') return !showArchived;
          return (thread['is_archived'] == true) == showArchived;
        }).toList();
        return Scaffold(
          body: ListView(
            key: const PageStorageKey('chat-list'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: [
              PageHeading(
                title: 'الدردشة',
                subtitle: showArchived ? 'المحادثات المؤرشفة' : 'اختر أي موظف لمراسلته أو أنشئ مجموعة عمل',
                icon: Icons.chat_bubble_outline_rounded,
                action: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.outlined(
                      tooltip: showArchived ? 'المحادثات' : 'الأرشيف',
                      onPressed: () => setState(() => showArchived = !showArchived),
                      icon: Icon(showArchived ? Icons.chat_bubble_outline_rounded : Icons.archive_outlined),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filled(
                      tooltip: 'مجموعة جديدة',
                      onPressed: threadBusy ? null : createThread,
                      icon: const Icon(Icons.group_add_rounded),
                    ),
                  ],
                ),
              ),
              TextField(
                controller: threadSearch,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'ابحث في المحادثات',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: threadSearch.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح البحث',
                          onPressed: () {
                            threadSearch.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              SectionHeader(title: '${showArchived ? 'المؤرشفة' : 'المحادثات'} (${filteredThreads.length})'),
              if (filteredThreads.isEmpty)
                const EmptyState(icon: Icons.chat_bubble_outline_rounded, text: 'لا توجد محادثات بعد')
              else
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: panelSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < filteredThreads.length; i++) ...[
                        ChatThreadTile(
                          thread: filteredThreads[i],
                          currentEmployeeId: widget.session.id,
                          onTap: () => openThread(filteredThreads[i]),
                          onLongPress: () => showThreadActions(filteredThreads[i]),
                        ),
                        if (i != filteredThreads.length - 1) const Divider(indent: 78, height: 1),
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

class ChatThreadTile extends StatelessWidget {
  const ChatThreadTile({
    super.key,
    required this.thread,
    this.currentEmployeeId = '',
    required this.onTap,
    this.onLongPress,
  });

  final Map<String, dynamic> thread;
  final String currentEmployeeId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final type = thread['thread_type']?.toString() ?? 'general';
    final general = type == 'general';
    final group = type == 'group';
    final contact = type == 'contact';
    final latest = thread['last_message'] as Map<String, dynamic>?;
    final senderName = thread['last_sender_name']?.toString();
    final latestIsMine = latest?['sender_id']?.toString() == currentEmployeeId;
    final unread = intValue(thread['unread_count']);
    final emptySubtitle = contact
        ? 'بدء محادثة خاصة'
        : chatTypeLabel(type);
    final avatarName = thread['thread_avatar_name']?.toString() ?? thread['title']?.toString() ?? 'محادثة';
    final avatarUrl = thread['thread_avatar_url'] as String?;
    return Material(
      color: panelSurface,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          child: Row(
            children: [
              if (general || group)
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: (general ? accentColor : infoColor).withValues(alpha: 0.11),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    general ? Icons.campaign_rounded : Icons.groups_rounded,
                    color: general ? accentColor : infoColor,
                  ),
                )
              else
                EmployeeAvatar(name: avatarName, imageUrl: avatarUrl, radius: 25),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            thread['title']?.toString() ?? 'محادثة',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                          ),
                        ),
                        if (latest != null)
                          Text(chatListTime(latest['created_at']), style: const TextStyle(color: mutedInk, fontSize: 10)),
                        if (thread['is_pinned'] == true) ...[
                          const SizedBox(width: 5),
                          const Icon(Icons.push_pin_rounded, size: 14, color: brandColor),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      latest == null
                          ? emptySubtitle
                          : '${latestIsMine ? 'أنت: ' : senderName == null ? '' : '$senderName: '}${latest['body'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: mutedInk, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (unread > 0)
                    Badge(
                      label: Text(unread > 99 ? '99+' : '$unread'),
                      backgroundColor: brandColor,
                    )
                  else
                    const Icon(Icons.chevron_left_rounded, color: mutedInk, size: 20),
                  if (thread['is_muted'] == true)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Icon(Icons.notifications_off_rounded, color: mutedInk, size: 14),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatAttachmentDraft {
  const ChatAttachmentDraft({required this.name, required this.bytes, required this.mimeType});

  final String name;
  final Uint8List bytes;
  final String mimeType;
}

String chatAttachmentMime(String extension) {
  switch (extension.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'pdf':
      return 'application/pdf';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    default:
      return 'application/octet-stream';
  }
}

class ChatThreadPage extends StatefulWidget {
  const ChatThreadPage({super.key, required this.session, required this.thread});

  final EmployeeSession session;
  final Map<String, dynamic> thread;

  @override
  State<ChatThreadPage> createState() => _ChatThreadPageState();
}

class _ChatThreadPageState extends State<ChatThreadPage> with WidgetsBindingObserver {
  final message = TextEditingController();
  final composerFocus = FocusNode();
  final scrollController = ScrollController();
  final messageKeys = <String, GlobalKey>{};
  final senderProfiles = <String, Map<String, dynamic>>{};
  final pendingAttachments = <ChatAttachmentDraft>[];
  late Future<List<Map<String, dynamic>>> future;
  List<Map<String, dynamic>>? latestMessages;
  Map<String, dynamic>? replyingTo;
  Map<String, dynamic>? editingMessage;
  Timer? timer;
  Timer? typingTimer;
  Timer? realtimeReconnectTimer;
  RealtimeChannel? liveChannel;
  RealtimeChannel? messagesChannel;
  bool sendingMessage = false;
  double? attachmentUploadProgress;
  bool refreshingMessages = false;
  bool refreshMessagesAgain = false;
  bool showNewMessageHint = false;
  bool realtimeConnected = false;
  String? messageSyncError;
  int newMessageCount = 0;
  String? lastRenderedMessageId;
  String? previousActiveChatThreadId;
  String? typingEmployeeName;
  bool otherParticipantOnline = false;
  DateTime? otherParticipantLastSeen;
  int messageLimit = 120;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    previousActiveChatThreadId = activeChatThreadId;
    activeChatThreadId = '${widget.thread['id']}';
    future = loadAndRememberMessages();
    message.addListener(handleTypingChanged);
    setupLiveConversation();
    setupMessageChanges();
    unawaited(loadOtherParticipantLastSeen());
    scrollController.addListener(handleMessageScroll);
    // Realtime can report a connected channel even when a table is not yet
    // published. Keep a light reconciliation loop so another device's message
    // still appears without leaving and reopening the conversation.
    timer = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(refreshMessages()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (activeChatThreadId == '${widget.thread['id']}') activeChatThreadId = previousActiveChatThreadId;
    timer?.cancel();
    typingTimer?.cancel();
    realtimeReconnectTimer?.cancel();
    if (messagesChannel != null) supabase.removeChannel(messagesChannel!);
    if (liveChannel != null) {
      liveChannel!.untrack();
      supabase.removeChannel(liveChannel!);
    }
    message.removeListener(handleTypingChanged);
    scrollController
      ..removeListener(handleMessageScroll)
      ..dispose();
    composerFocus.dispose();
    message.dispose();
    unawaited(touchEmployeePresence(widget.session.id, online: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!realtimeConnected) setupMessageChanges();
      unawaited(refreshMessages());
      unawaited(markThreadDelivered());
    }
  }

  void setupMessageChanges() {
    if (messagesChannel != null) supabase.removeChannel(messagesChannel!);
    messagesChannel = supabase.channel('ansar-chat-messages-${widget.thread['id']}-${widget.session.id}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ansar_chat_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'thread_id',
          value: '${widget.thread['id']}',
        ),
        callback: handleInsertedMessage,
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'ansar_chat_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'thread_id',
          value: '${widget.thread['id']}',
        ),
        callback: (_) => unawaited(refreshMessages()),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'ansar_chat_messages',
        callback: (_) => unawaited(refreshMessages()),
      )
      ..subscribe((status, error) {
        if (!mounted) return;
        final connected = status == RealtimeSubscribeStatus.subscribed;
        realtimeReconnectTimer?.cancel();
        if (realtimeConnected != connected || (connected && messageSyncError != null)) {
          setState(() {
            realtimeConnected = connected;
            if (connected) messageSyncError = null;
          });
        }
        if (connected) {
          unawaited(refreshMessages());
        } else {
          realtimeReconnectTimer = Timer(const Duration(seconds: 3), () {
            if (mounted && !realtimeConnected) setupMessageChanges();
          });
        }
      });
  }

  void handleInsertedMessage(PostgresChangePayload payload) {
    if (!mounted) return;
    final row = Map<String, dynamic>.from(payload.newRecord);
    if ('${row['thread_id']}' != '${widget.thread['id']}') return;
    final current = latestMessages ?? <Map<String, dynamic>>[];
    if (current.any((message) => '${message['id']}' == '${row['id']}')) {
      unawaited(refreshMessages());
      return;
    }
    final mine = row['sender_id'] == widget.session.id;
    final shouldFollow = mine || isNearMessageBottom;
    final optimistic = {
      ...row,
      'sender_name': mine ? widget.session.name : 'موظف',
      'sender_avatar_url': mine ? widget.session.avatarUrl : null,
      'receipt_status': 'sent',
      'receipt_details': const <Map<String, dynamic>>[],
    };
    final updated = [...current, optimistic];
    setState(() {
      latestMessages = updated;
      future = Future.value(updated);
      if (!shouldFollow && !mine) {
        newMessageCount += 1;
        showNewMessageHint = true;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !shouldFollow) return;
      scrollToMessageBottom();
      unawaited(markThreadRead());
    });
    unawaited(markThreadDelivered());
    unawaited(refreshMessages());
  }

  void setupLiveConversation() {
    final participantIds = (widget.thread['participant_ids'] as List?)?.map((value) => '$value').toSet() ?? <String>{};
    liveChannel = supabase.channel('ansar-chat-live-${widget.thread['id']}')
      ..onBroadcast(
        event: 'typing',
        callback: (payload) {
          final employeeId = payload['employee_id']?.toString();
          final general = widget.thread['thread_type'] == 'general';
          if (!mounted || employeeId == null || employeeId == widget.session.id || (!general && !participantIds.contains(employeeId))) return;
          final active = payload['typing'] == true;
          typingTimer?.cancel();
          setState(() => typingEmployeeName = active ? payload['employee_name']?.toString() ?? 'موظف' : null);
          if (active) {
            typingTimer = Timer(const Duration(seconds: 3), () {
              if (mounted) setState(() => typingEmployeeName = null);
            });
          }
        },
      )
      ..onPresenceSync((_) => updateOnlinePresence(participantIds))
      ..onPresenceJoin((_) => updateOnlinePresence(participantIds))
      ..onPresenceLeave((_) => updateOnlinePresence(participantIds))
      ..subscribe((status, error) async {
        if (status == RealtimeSubscribeStatus.subscribed) {
          await liveChannel?.track({
            'employee_id': widget.session.id,
            'employee_name': widget.session.name,
            'online_at': DateTime.now().toUtc().toIso8601String(),
          });
          await touchEmployeePresence(widget.session.id, online: true);
        }
      });
  }

  void updateOnlinePresence(Set<String> participantIds) {
    if (!mounted || liveChannel == null) return;
    final state = liveChannel!.presenceState().toString();
    final others = participantIds.where((id) => id != widget.session.id);
    final online = others.any(state.contains);
    if (online != otherParticipantOnline) setState(() => otherParticipantOnline = online);
    if (!online) unawaited(loadOtherParticipantLastSeen());
  }

  Future<void> loadOtherParticipantLastSeen() async {
    if (widget.thread['thread_type'] != 'direct') return;
    final participantIds = (widget.thread['participant_ids'] as List?)?.map((value) => '$value').toList() ?? <String>[];
    final others = participantIds.where((id) => id != widget.session.id).toList();
    if (others.isEmpty) return;
    try {
      final rows = await supabase.from('ansar_employees').select('last_seen_at').eq('id', others.first).limit(1);
      final value = rows.isEmpty ? null : DateTime.tryParse(rows.first['last_seen_at']?.toString() ?? '')?.toLocal();
      if (mounted) setState(() => otherParticipantLastSeen = value);
    } catch (_) {
      // Last seen appears after the platform migration is installed.
    }
  }

  String get conversationPresenceLabel {
    if (typingEmployeeName != null) return '${typingEmployeeName!} يكتب الآن...';
    if (widget.thread['thread_type'] == 'direct' && otherParticipantOnline) return 'متصل الآن';
    if (widget.thread['thread_type'] == 'direct' && otherParticipantLastSeen != null) {
      return 'آخر ظهور ${formatDateTime(otherParticipantLastSeen!)}';
    }
    if (widget.thread['thread_type'] == 'group') {
      return '${(widget.thread['participant_ids'] as List?)?.length ?? 0} أعضاء';
    }
    return chatTypeLabel(widget.thread['thread_type'] as String? ?? 'general');
  }

  void handleTypingChanged() {
    if (liveChannel == null || editingMessage != null) return;
    final hasText = message.text.trim().isNotEmpty;
    unawaited(sendTypingState(hasText));
  }

  Future<void> sendTypingState(bool typing) async {
    await liveChannel?.sendBroadcastMessage(
      event: 'typing',
      payload: {
        'employee_id': widget.session.id,
        'employee_name': widget.session.name,
        'typing': typing,
      },
    );
  }

  Future<void> refreshMessages() async {
    if (!mounted) return;
    if (refreshingMessages) {
      refreshMessagesAgain = true;
      return;
    }
    refreshingMessages = true;
    try {
      final loaded = await loadMessages();
      if (!mounted) return;
      if (messageSyncError != null) setState(() => messageSyncError = null);
      if (chatMessageSnapshotsEqual(latestMessages, loaded)) return;
      setState(() {
        latestMessages = loaded;
        future = Future.value(loaded);
      });
    } catch (_) {
      if (mounted && messageSyncError == null) {
        setState(() => messageSyncError = 'تعذر تحديث الرسائل مؤقتاً، نعرض آخر نسخة محفوظة');
      }
    } finally {
      refreshingMessages = false;
      if (refreshMessagesAgain && mounted) {
        refreshMessagesAgain = false;
        unawaited(refreshMessages());
      }
    }
  }

  bool get isNearMessageBottom {
    if (!scrollController.hasClients) return true;
    return scrollController.position.maxScrollExtent - scrollController.offset < 110;
  }

  void handleMessageScroll() {
    if (showNewMessageHint && isNearMessageBottom && mounted) {
      setState(() {
        showNewMessageHint = false;
        newMessageCount = 0;
      });
      unawaited(markThreadRead());
    }
  }

  void syncMessageScroll(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return;
    final last = messages.last;
    final messageId = '${last['id']}';
    if (messageId == lastRenderedMessageId) return;
    final previousMessageId = lastRenderedMessageId;
    final initial = previousMessageId == null;
    final shouldFollow = initial || isNearMessageBottom || last['sender_id'] == widget.session.id;
    lastRenderedMessageId = messageId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (shouldFollow) {
        scrollToMessageBottom(jump: initial);
        unawaited(markThreadRead());
      } else if (!showNewMessageHint) {
        final previousIndex = messages.indexWhere((row) => '${row['id']}' == previousMessageId);
        final added = previousIndex < 0 ? 1 : max(1, messages.length - previousIndex - 1);
        setState(() {
          showNewMessageHint = true;
          newMessageCount = max(newMessageCount, added);
        });
      }
    });
  }

  void scrollToMessageBottom({bool jump = false}) {
    if (!scrollController.hasClients) return;
    final target = scrollController.position.maxScrollExtent;
    if (jump) {
      scrollController.jumpTo(target);
      unawaited(markThreadRead());
    } else {
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      unawaited(Future<void>.delayed(const Duration(milliseconds: 320), markThreadRead));
    }
    if (showNewMessageHint && mounted) {
      setState(() {
        showNewMessageHint = false;
        newMessageCount = 0;
      });
    }
  }

  Future<void> markThreadDelivered() async {
    try {
      await supabase.rpc('ansar_mark_chat_delivered', params: {
        'p_employee_id': widget.session.id,
        'p_thread_id': '${widget.thread['id']}',
      });
    } catch (_) {
      // Delivery is retried by the next message refresh.
    }
  }

  Future<void> markThreadRead() async {
    if (!isNearMessageBottom) return;
    try {
      await supabase.rpc('ansar_mark_chat_read', params: {
        'p_employee_id': widget.session.id,
        'p_thread_id': '${widget.thread['id']}',
      });
    } catch (_) {
      // Read state is retried when the conversation refreshes.
    }
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
        .order('created_at', ascending: false)
        .limit(messageLimit);
    final allMessages = rows.cast<Map<String, dynamic>>().reversed.toList();
    var hiddenMessageIds = <String>{};
    try {
      final messageIds = allMessages.map((row) => '${row['id']}').toList();
      if (messageIds.isEmpty) return <Map<String, dynamic>>[];
      final hiddenRows = await supabase
          .from('ansar_chat_message_hidden')
          .select('message_id')
          .eq('employee_id', widget.session.id)
          .inFilter('message_id', messageIds);
      hiddenMessageIds = hiddenRows.map((row) => '${row['message_id']}').toSet();
    } catch (_) {
      // The chat remains usable before the optional per-user deletion migration is installed.
    }
    final messages = allMessages.where((row) => !hiddenMessageIds.contains('${row['id']}')).toList();
    List<Map<String, dynamic>> receiptRows = [];
    try {
      final messageIds = messages.map((row) => '${row['id']}').toList();
      if (messageIds.isNotEmpty) {
        final rows = await supabase
            .from('ansar_chat_message_receipts')
            .select('message_id, employee_id, status, sent_at, delivered_at, read_at')
            .inFilter('message_id', messageIds);
        receiptRows = rows.cast<Map<String, dynamic>>();
      }
      await markThreadDelivered();
      if (isNearMessageBottom) await markThreadRead();
    } catch (_) {
      // Receipts are optional until the platform migration is installed.
    }
    final transferById = <String, Map<String, dynamic>>{};
    final transferIds = messages
        .map((row) => row['transfer_order_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (transferIds.isNotEmpty) {
      try {
        final transferRows = await supabase
            .from('ansar_transfer_orders')
            .select('id, order_no, status, from_branch_num, to_branch_num')
            .inFilter('id', transferIds);
        for (final transfer in transferRows.cast<Map<String, dynamic>>()) {
          transferById['${transfer['id']}'] = transfer;
        }
      } catch (_) {
        // The message still opens the transfer even if its live status cannot be fetched briefly.
      }
    }
    final messageById = <String, Map<String, dynamic>>{
      for (final row in messages) if (row['id'] != null) '${row['id']}': row,
    };
    final missingReplyIds = messages
        .map((row) => row['reply_to_id']?.toString())
        .whereType<String>()
        .where((id) => !messageById.containsKey(id))
        .where((id) => !hiddenMessageIds.contains(id))
        .toSet()
        .toList();
    if (missingReplyIds.isNotEmpty) {
      try {
        final replyRows = await supabase.from('ansar_chat_messages').select().inFilter('id', missingReplyIds);
        for (final row in replyRows.cast<Map<String, dynamic>>()) {
          if (row['id'] != null) messageById['${row['id']}'] = row;
        }
      } catch (_) {
        // Replies still render with a generic preview if the original is outside the loaded page.
      }
    }
    final senderIds = <String>{
      ...messages.map((row) => row['sender_id']?.toString()).whereType<String>(),
      ...messageById.values.map((row) => row['sender_id']?.toString()).whereType<String>(),
      ...receiptRows.map((row) => row['employee_id']?.toString()).whereType<String>(),
    }.toList();
    final missingSenderIds = senderIds.where((id) => !senderProfiles.containsKey(id)).toList();
    final employeeRows = missingSenderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase
            .from('ansar_employees')
            .select('id, display_name, full_name, avatar_url')
            .inFilter('id', missingSenderIds);
    for (final row in employeeRows.cast<Map<String, dynamic>>()) {
      senderProfiles['${row['id']}'] = row;
    }
    final employees = senderProfiles;
    final receiptsByMessage = <String, List<Map<String, dynamic>>>{};
    for (final receipt in receiptRows) {
      receiptsByMessage.putIfAbsent('${receipt['message_id']}', () => <Map<String, dynamic>>[]).add(receipt);
    }
    return messages.map((row) {
      final employee = employees['${row['sender_id']}'];
      final reply = messageById[row['reply_to_id']?.toString()];
      final replyEmployee = reply == null ? null : employees['${reply['sender_id']}'];
      final receipts = receiptsByMessage['${row['id']}'] ?? <Map<String, dynamic>>[];
      final receiptStatus = receipts.isEmpty
          ? 'sent'
          : receipts.every((receipt) => receipt['status'] == 'read')
              ? 'read'
              : receipts.every((receipt) => {'delivered', 'read'}.contains(receipt['status']))
                  ? 'delivered'
                  : 'sent';
      return {
        ...row,
        'sender_name': employee == null
            ? 'موظف'
            : (employee['display_name'] ?? employee['full_name'] ?? 'موظف').toString(),
        'sender_avatar_url': employee?['avatar_url'],
        'reply_preview_body': reply == null
            ? null
            : (reply['deleted_at'] == null ? reply['body']?.toString() : 'تم حذف هذه الرسالة'),
        'reply_preview_sender': reply == null
            ? null
            : (replyEmployee?['display_name'] ?? replyEmployee?['full_name'] ?? 'موظف').toString(),
        'receipt_status': receiptStatus,
        'receipt_details': receipts
            .map((receipt) => {
                  ...receipt,
                  'employee_name': employeeDisplayName(employees['${receipt['employee_id']}'] ?? const <String, dynamic>{}),
                  'avatar_url': employees['${receipt['employee_id']}']?['avatar_url'],
                })
            .toList(),
        'transfer_status': transferById[row['transfer_order_id']?.toString()]?['status'],
      };
    }).toList();
  }

  Future<void> pickAttachments() async {
    if (pendingAttachments.length >= 5 || sendingMessage) return;
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: brandColor),
              title: const Text('صورة من المعرض'),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: brandColor),
              title: const Text('التقاط صورة'),
              onTap: () => Navigator.pop(sheetContext, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_rounded, color: infoColor),
              title: const Text('اختيار صور أو ملفات'),
              onTap: () => Navigator.pop(sheetContext, 'files'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    if (source == 'gallery' || source == 'camera') {
      await pickChatImage(source == 'camera' ? ImageSource.camera : ImageSource.gallery);
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'pdf', 'doc', 'docx', 'xls', 'xlsx'],
    );
    if (result == null || !mounted) return;
    final remaining = 5 - pendingAttachments.length;
    final selected = <ChatAttachmentDraft>[];
    for (final file in result.files.take(remaining)) {
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) bytes = await File(file.path!).readAsBytes();
      if (bytes == null) continue;
      final mime = chatAttachmentMime(file.extension ?? file.name.split('.').last);
      if (mime.startsWith('image/') && bytes.length > 1200000 && file.path != null) {
        final compressed = await FlutterImageCompress.compressWithFile(
          file.path!,
          minWidth: 1600,
          minHeight: 1600,
          quality: 76,
        );
        if (compressed != null) bytes = compressed;
      }
      if (bytes.length > 10 * 1024 * 1024) {
        if (mounted) showSnack(context, 'تم تجاهل ${file.name}: الحد الأقصى 10 ميغابايت');
        continue;
      }
      selected.add(ChatAttachmentDraft(name: file.name, bytes: bytes, mimeType: mime));
    }
    if (selected.isNotEmpty) setState(() => pendingAttachments.addAll(selected));
  }

  Future<void> pickChatImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(source: source, imageQuality: 92, maxWidth: 2200);
      if (picked == null || !mounted) return;
      Uint8List bytes = await picked.readAsBytes();
      if (bytes.length > 1200000) {
        bytes = await FlutterImageCompress.compressWithList(bytes, minWidth: 1600, minHeight: 1600, quality: 76);
      }
      if (bytes.length > 10 * 1024 * 1024) {
        showSnack(context, 'حجم الصورة أكبر من 10 ميغابايت');
        return;
      }
      final extension = picked.name.split('.').last.toLowerCase();
      setState(() => pendingAttachments.add(ChatAttachmentDraft(
            name: picked.name,
            bytes: bytes,
            mimeType: chatAttachmentMime(extension),
          )));
    } catch (error) {
      if (mounted) showSnack(context, chatAttachmentError(error));
    }
  }

  Future<List<Map<String, Object?>>> uploadPendingAttachments() async {
    final uploaded = <Map<String, Object?>>[];
    try {
      for (var index = 0; index < pendingAttachments.length; index++) {
        if (mounted) setState(() => attachmentUploadProgress = index / pendingAttachments.length);
        final attachment = pendingAttachments[index];
        final safeName = attachment.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '${widget.thread['id']}/${DateTime.now().microsecondsSinceEpoch}-$index-$safeName';
        await supabase.storage.from('ansar-chat').uploadBinary(
              path,
              attachment.bytes,
              fileOptions: FileOptions(contentType: attachment.mimeType, upsert: false),
            );
        uploaded.add({
          'path': path,
          'name': attachment.name,
          'size': attachment.bytes.length,
          'mime_type': attachment.mimeType,
        });
      }
      if (mounted) setState(() => attachmentUploadProgress = 1);
      return uploaded;
    } catch (error) {
      final paths = uploaded.map((item) => item['path']?.toString()).whereType<String>().toList();
      if (paths.isNotEmpty) {
        try {
          await supabase.storage.from('ansar-chat').remove(paths);
        } catch (_) {
          // A later maintenance pass can remove an orphan if cleanup is temporarily unavailable.
        }
      }
      throw Exception(chatAttachmentError(error));
    }
  }

  Future<void> sendMessage() async {
    final body = message.text.trim();
    if ((body.isEmpty && pendingAttachments.isEmpty) || sendingMessage) return;
    if (editingMessage != null) {
      if (body.isEmpty) return;
      await saveEditedMessage(body);
      return;
    }
    setState(() => sendingMessage = true);
    try {
      final reply = replyingTo;
      final attachments = await uploadPendingAttachments();
      final inserted = await supabase
          .from('ansar_chat_messages')
          .insert({
            'thread_id': widget.thread['id'],
            'sender_id': widget.session.id,
            'body': body,
            'message_type': attachments.isEmpty ? 'text' : 'attachment',
            if (attachments.isNotEmpty) 'attachments': attachments,
            if (reply?['id'] != null) 'reply_to_id': '${reply!['id']}',
          })
          .select()
          .single();
      if (mounted) {
        message.clear();
        pendingAttachments.clear();
        final updated = <Map<String, dynamic>>[
          for (final row in latestMessages ?? <Map<String, dynamic>>[])
            if ('${row['id']}' != '${inserted['id']}') row,
          {
            ...inserted,
            'sender_name': widget.session.name,
            'sender_avatar_url': widget.session.avatarUrl,
            'reply_preview_body': reply?['body']?.toString(),
            'reply_preview_sender': reply == null
                ? null
                : (reply['sender_id'] == widget.session.id ? 'أنت' : reply['sender_name']?.toString() ?? 'موظف'),
          },
        ];
        setState(() {
          replyingTo = null;
          latestMessages = updated;
          future = Future.value(updated);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) scrollToMessageBottom();
        });
      }
      unawaited(touchThread());
      unawaited(enqueueChatNotification(
        thread: widget.thread,
        sender: widget.session,
        body: body.isEmpty
            ? 'أرسل ${attachments.length == 1 ? 'مرفقاً' : '${attachments.length} مرفقات'}'
            : (body.length > 80 ? '${body.substring(0, 80)}...' : body),
      ));
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    } finally {
      if (mounted) {
        setState(() {
          sendingMessage = false;
          attachmentUploadProgress = null;
        });
      }
    }
  }

  Future<void> saveEditedMessage(String body) async {
    final target = editingMessage;
    if (target == null || sendingMessage) return;
    setState(() => sendingMessage = true);
    final editedAt = DateTime.now().toUtc().toIso8601String();
    try {
      await supabase.from('ansar_chat_messages').update({
        'body': body,
        'edited_at': editedAt,
        'edited_by': widget.session.id,
      }).eq('id', target['id']);
      if (!mounted) return;
      message.clear();
      final updated = (latestMessages ?? <Map<String, dynamic>>[])
          .map((row) => '${row['id']}' == '${target['id']}' ? {...row, 'body': body, 'edited_at': editedAt} : row)
          .toList();
      setState(() {
        editingMessage = null;
        latestMessages = updated;
        future = Future.value(updated);
      });
      unawaited(touchThread());
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    } finally {
      if (mounted) setState(() => sendingMessage = false);
    }
  }

  Future<void> touchThread() async {
    try {
      await supabase
          .from('ansar_chat_threads')
          .update({'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', widget.thread['id']);
    } catch (_) {
      // The message is already saved; a timestamp failure must not restore the composer text.
    }
  }

  Future<void> deleteMessage(Map<String, dynamic> row) async {
    if (!canDeleteChatMessageForEveryone(row, widget.session)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الرسالة لدى الجميع؟'),
        content: const Text('ستظهر للمشاركين عبارة تفيد بأن الرسالة حُذفت.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: dangerColor),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف لدى الجميع'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      await supabase.from('ansar_chat_messages').update({
        'deleted_at': deletedAt,
        'deleted_by': widget.session.id,
      }).eq('id', row['id']);
      if (!mounted) return;
      final updated = (latestMessages ?? <Map<String, dynamic>>[])
          .map((item) => '${item['id']}' == '${row['id']}' ? {...item, 'deleted_at': deletedAt} : item)
          .toList();
      setState(() {
        latestMessages = updated;
        future = Future.value(updated);
        if ('${editingMessage?['id']}' == '${row['id']}') editingMessage = null;
        if ('${replyingTo?['id']}' == '${row['id']}') replyingTo = null;
      });
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    }
  }

  Future<void> hideMessageForMe(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الرسالة لديك؟'),
        content: const Text('ستختفي الرسالة من حسابك فقط، وستبقى ظاهرة لبقية المشاركين.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: dangerColor),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف لدي'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await supabase.from('ansar_chat_message_hidden').upsert({
        'employee_id': widget.session.id,
        'message_id': '${row['id']}',
      }, onConflict: 'employee_id,message_id');
      if (!mounted) return;
      final updated = (latestMessages ?? <Map<String, dynamic>>[])
          .where((item) => '${item['id']}' != '${row['id']}')
          .toList();
      setState(() {
        latestMessages = updated;
        future = Future.value(updated);
        if ('${editingMessage?['id']}' == '${row['id']}') editingMessage = null;
        if ('${replyingTo?['id']}' == '${row['id']}') replyingTo = null;
      });
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    }
  }

  void beginReply(Map<String, dynamic> row) {
    if (row['deleted_at'] != null) return;
    setState(() {
      replyingTo = row;
      editingMessage = null;
    });
    composerFocus.requestFocus();
  }

  void beginEdit(Map<String, dynamic> row) {
    if (row['sender_id'] != widget.session.id || row['deleted_at'] != null) return;
    message.text = row['body']?.toString() ?? '';
    message.selection = TextSelection.collapsed(offset: message.text.length);
    setState(() {
      editingMessage = row;
      replyingTo = null;
    });
    composerFocus.requestFocus();
  }

  void cancelComposerAction() {
    message.clear();
    setState(() {
      replyingTo = null;
      editingMessage = null;
    });
  }

  Future<void> showMessageActions(Map<String, dynamic> row) async {
    final deleted = row['deleted_at'] != null;
    final mine = row['sender_id'] == widget.session.id;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!deleted)
                ListTile(
                  leading: const Icon(Icons.reply_rounded, color: brandColor),
                  title: const Text('رد'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    beginReply(row);
                  },
                ),
              if (!deleted)
                ListTile(
                  leading: const Icon(Icons.forward_rounded, color: infoColor),
                  title: const Text('تحويل إلى محادثة'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(forwardMessage(row));
                  },
                ),
              if (!deleted)
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('نسخ النص'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: row['body']?.toString() ?? ''));
                    Navigator.pop(sheetContext);
                    showSnack(context, 'تم نسخ الرسالة');
                  },
                ),
              if (mine && !deleted)
                ListTile(
                  leading: const Icon(Icons.edit_rounded, color: accentColor),
                  title: const Text('تعديل الرسالة'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    beginEdit(row);
                  },
                ),
              if (mine && !deleted)
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded, color: infoColor),
                  title: const Text('معلومات الرسالة'),
                  subtitle: const Text('حالة الوصول والقراءة لكل مستلم'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(showMessageInfo(row));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined, color: dangerColor),
                title: const Text('حذف لدي', style: TextStyle(color: dangerColor)),
                subtitle: const Text('يختفي من حسابك فقط'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(hideMessageForMe(row));
                },
              ),
              if (canDeleteChatMessageForEveryone(row, widget.session) && !deleted)
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded, color: dangerColor),
                  title: const Text('حذف لدى الجميع', style: TextStyle(color: dangerColor)),
                  subtitle: const Text('متاح لمرسل الرسالة فقط'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(deleteMessage(row));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> showMessageInfo(Map<String, dynamic> row) async {
    final details = (row['receipt_details'] as List?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.68,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.fact_check_outlined, color: brandColor),
                title: const Text('معلومات الرسالة', style: TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text(row['body']?.toString() ?? 'مرفق'),
              ),
              const Divider(height: 1),
              Expanded(
                child: details.isEmpty
                    ? const EmptyState(icon: Icons.schedule_rounded, text: 'لم تتوفر إيصالات المستلمين بعد')
                    : ListView.separated(
                        itemCount: details.length,
                        separatorBuilder: (_, __) => const Divider(indent: 64, height: 1),
                        itemBuilder: (context, index) {
                          final detail = details[index];
                          final status = detail['status']?.toString() ?? 'sent';
                          final label = status == 'read' ? 'تمت القراءة' : status == 'delivered' ? 'تم الوصول' : 'تم الإرسال';
                          final time = detail['read_at'] ?? detail['delivered_at'] ?? detail['sent_at'];
                          return ListTile(
                            leading: EmployeeAvatar(
                              name: detail['employee_name']?.toString() ?? 'موظف',
                              imageUrl: detail['avatar_url']?.toString(),
                              radius: 21,
                            ),
                            title: Text(detail['employee_name']?.toString() ?? 'موظف', style: const TextStyle(fontWeight: FontWeight.w800)),
                            subtitle: Text('$label · ${formatEventTime(time)}'),
                            trailing: Icon(
                              status == 'read' ? Icons.done_all_rounded : status == 'delivered' ? Icons.done_all_rounded : Icons.done_rounded,
                              color: status == 'read' ? infoColor : mutedInk,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> forwardMessage(Map<String, dynamic> row) async {
    final count = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: ForwardMessagePage(session: widget.session, sourceMessage: row),
        ),
      ),
    );
    if (mounted && count != null) showSnack(context, 'تم تحويل الرسالة إلى $count محادثة');
  }

  Future<void> openSenderProfile(Map<String, dynamic> row) async {
    final senderId = row['sender_id']?.toString();
    if (senderId == null || senderId == widget.session.id) return;
    await openEmployeePublicProfile(context, widget.session, senderId);
  }

  Future<void> openThreadHeader() async {
    if (widget.thread['thread_type'] != 'direct') {
      await openThreadInfo();
      return;
    }
    final ids = (widget.thread['participant_ids'] as List?)?.map((value) => '$value').toList() ?? const <String>[];
    final others = ids.where((id) => id != widget.session.id).toList();
    if (others.isEmpty) {
      await openThreadInfo();
      return;
    }
    await openEmployeePublicProfile(context, widget.session, others.first);
  }

  Future<void> openThreadInfo() async {
    final result = await Navigator.of(context).push<ChatInfoResult>(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: ChatInfoPage(session: widget.session, thread: widget.thread),
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.leftThread) {
      Navigator.pop(context);
      return;
    }
    if (result.title != null) setState(() => widget.thread['title'] = result.title);
  }

  Future<void> searchConversation() async {
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('بحث داخل المحادثة'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: 'اكتب كلمة أو جملة', prefixIcon: Icon(Icons.search_rounded)),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('بحث')),
        ],
      ),
    );
    controller.dispose();
    if (query == null || query.isEmpty || !mounted) return;
    try {
      final safeQuery = safeSearchPattern(query);
      final rows = await supabase
          .from('ansar_chat_messages')
          .select('id, body, sender_id, created_at')
          .eq('thread_id', widget.thread['id'])
          .isFilter('deleted_at', null)
          .ilike('body', '%$safeQuery%')
          .order('created_at', ascending: false)
          .limit(50);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.75,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.manage_search_rounded, color: brandColor),
                  title: Text('نتائج البحث عن «$query»', style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text('${rows.length} نتيجة'),
                ),
                const Divider(height: 1),
                Expanded(
                  child: rows.isEmpty
                      ? const EmptyState(icon: Icons.search_off_rounded, text: 'لا توجد رسائل مطابقة')
                      : ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return ListTile(
                              leading: const Icon(Icons.chat_bubble_outline_rounded),
                              title: Text(row['body']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(formatEventTime(row['created_at'])),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(jumpToMessage('${row['id']}'));
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    }
  }

  Future<void> jumpToMessage(String messageId) async {
    if (messageKeys[messageId]?.currentContext == null) {
      messageLimit = 500;
      final loaded = await loadMessages();
      if (!mounted) return;
      setState(() {
        latestMessages = loaded;
        future = Future.value(loaded);
      });
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    final targetContext = messageKeys[messageId]?.currentContext;
    if (targetContext == null || !targetContext.mounted) {
      if (mounted) showSnack(context, 'الرسالة أقدم من النطاق المحمل حالياً');
      return;
    }
    await Scrollable.ensureVisible(targetContext, duration: const Duration(milliseconds: 320), alignment: 0.35);
  }

  Future<void> openTransferMessage(Map<String, dynamic> row) async {
    await openTransferNotification(context, widget.session, {
      'type': 'transfer_shared',
      'route': 'transfer',
      'order_id': row['transfer_order_id'],
    });
  }

  Future<void> openAttachment(Map<String, dynamic> attachment) async {
    final path = attachment['path']?.toString();
    if (path == null || path.isEmpty) return;
    try {
      final url = await supabase.storage.from('ansar-chat').createSignedUrl(path, 600);
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened && mounted) showSnack(context, 'تعذر فتح المرفق على هذا الجهاز');
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    }
  }

  void scrollToReply(String? messageId) {
    if (messageId == null) return;
    final targetContext = messageKeys[messageId]?.currentContext;
    if (targetContext == null) {
      showSnack(context, 'الرسالة الأصلية أقدم من الرسائل المعروضة');
      return;
    }
    Scrollable.ensureVisible(targetContext, duration: const Duration(milliseconds: 280), alignment: 0.35);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffeef3f1),
      appBar: AppBar(
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: openThreadHeader,
          child: Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: accentColor.withValues(alpha: 0.12),
                child: widget.thread['thread_type'] == 'direct'
                    ? EmployeeAvatar(
                        name: widget.thread['thread_avatar_name']?.toString() ?? widget.thread['title']?.toString() ?? 'محادثة',
                        imageUrl: widget.thread['thread_avatar_url']?.toString(),
                        radius: 17,
                      )
                    : Icon(
                        widget.thread['thread_type'] == 'general' ? Icons.campaign_rounded : Icons.forum_rounded,
                        color: widget.thread['thread_type'] == 'general' ? accentColor : brandColor,
                        size: 19,
                      ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.thread['title'] as String? ?? 'محادثة',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                    ),
                    Text(
                      conversationPresenceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: typingEmployeeName != null || otherParticipantOnline ? successColor : mutedInk,
                        fontSize: 10,
                        fontWeight: typingEmployeeName != null || otherParticipantOnline ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(tooltip: 'بحث في المحادثة', onPressed: searchConversation, icon: const Icon(Icons.search_rounded)),
          IconButton(tooltip: 'معلومات المحادثة', onPressed: openThreadInfo, icon: const Icon(Icons.info_outline_rounded)),
        ],
      ),
      body: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: realtimeConnected && messageSyncError == null
                ? const SizedBox.shrink()
                : Container(
                    key: ValueKey(messageSyncError ?? 'reconnecting'),
                    width: double.infinity,
                    color: warningSurface,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: accentColor),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            messageSyncError ?? 'جار إعادة الاتصال بالمحادثة...',
                            style: const TextStyle(fontSize: 11, color: inkColor, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
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
                syncMessageScroll(messages);
                return Stack(
                  children: [
                    ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(10, 14, 10, 22),
                      itemCount: messages.length,
                      itemBuilder: (context, i) {
                        final row = messages[i];
                        final mine = row['sender_id'] == widget.session.id;
                        final currentDate = parseChatDate(row['created_at']);
                        final previousDate = i == 0 ? null : parseChatDate(messages[i - 1]['created_at']);
                        final previousSender = i == 0 ? null : messages[i - 1]['sender_id'];
                        final startsSenderGroup = i == 0 ||
                            previousSender != row['sender_id'] ||
                            previousDate == null ||
                            !sameCalendarDay(previousDate, currentDate);
                        final messageId = '${row['id']}';
                        final itemKey = messageKeys.putIfAbsent(messageId, () => GlobalKey());
                        return KeyedSubtree(
                          key: itemKey,
                          child: ChatMessageBubble(
                            row: row,
                            mine: mine,
                            senderName: mine ? 'أنت' : row['sender_name'] as String? ?? 'موظف',
                            avatarUrl: mine ? widget.session.avatarUrl : row['sender_avatar_url'] as String?,
                            showDate: previousDate == null || !sameCalendarDay(previousDate, currentDate),
                            showIdentity: !mine && startsSenderGroup,
                            onLongPress: () => showMessageActions(row),
                            onAvatarTap: mine ? null : () => openSenderProfile(row),
                            onReplyTap: () => scrollToReply(row['reply_to_id']?.toString()),
                            onTransferTap: row['transfer_order_id'] == null ? null : () => openTransferMessage(row),
                            onAttachmentTap: openAttachment,
                          ),
                        );
                      },
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: showNewMessageHint
                            ? Center(
                                key: const ValueKey('new-message-hint'),
                                child: Material(
                                  color: brandColor,
                                  elevation: 3,
                                  borderRadius: BorderRadius.circular(22),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(22),
                                    onTap: () => scrollToMessageBottom(),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 20),
                                          const SizedBox(width: 5),
                                          Text(
                                            newMessageCount <= 1 ? 'رسالة جديدة' : '$newMessageCount رسائل جديدة',
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(key: ValueKey('no-new-message-hint')),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: const BoxDecoration(
                color: panelSurface,
                boxShadow: [BoxShadow(color: Color(0x16000000), blurRadius: 10, offset: Offset(0, -2))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (replyingTo != null || editingMessage != null) ...[
                    ChatComposerContextBar(
                      editing: editingMessage != null,
                      senderName: editingMessage != null
                          ? 'تعديل رسالتك'
                          : (replyingTo?['sender_id'] == widget.session.id
                              ? 'الرد على نفسك'
                              : 'الرد على ${replyingTo?['sender_name'] ?? 'موظف'}'),
                      body: (editingMessage ?? replyingTo)?['body']?.toString() ?? '',
                      onClose: cancelComposerAction,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (pendingAttachments.isNotEmpty) ...[
                    SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          for (var index = 0; index < pendingAttachments.length; index++)
                            InputChip(
                              avatar: Icon(
                                pendingAttachments[index].mimeType.startsWith('image/')
                                    ? Icons.image_outlined
                                    : Icons.description_outlined,
                                size: 17,
                              ),
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 150),
                                child: Text(pendingAttachments[index].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              onDeleted: sendingMessage ? null : () => setState(() => pendingAttachments.removeAt(index)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (attachmentUploadProgress != null) ...[
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: attachmentUploadProgress == 0 ? null : attachmentUploadProgress,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${(attachmentUploadProgress! * 100).round()}%',
                          style: const TextStyle(color: mutedInk, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'إرفاق صورة أو ملف',
                        onPressed: sendingMessage || editingMessage != null || pendingAttachments.length >= 5 ? null : pickAttachments,
                        icon: const Icon(Icons.attach_file_rounded, color: brandColor),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: softSurface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: borderColor),
                          ),
                          child: TextField(
                            controller: message,
                            focusNode: composerFocus,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              hintText: editingMessage != null ? 'عدّل الرسالة' : 'اكتب رسالة',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                            ),
                            onTap: () {
                              unawaited(Future<void>.delayed(const Duration(milliseconds: 260), () {
                                if (mounted) scrollToMessageBottom();
                              }));
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: IconButton.filled(
                          tooltip: editingMessage != null ? 'حفظ التعديل' : 'إرسال',
                          onPressed: sendingMessage ? null : sendMessage,
                          icon: sendingMessage
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : Icon(editingMessage != null ? Icons.check_rounded : Icons.send_rounded),
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
    );
  }
}

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.row,
    required this.mine,
    required this.senderName,
    required this.avatarUrl,
    required this.showDate,
    required this.showIdentity,
    required this.onLongPress,
    this.onAvatarTap,
    this.onReplyTap,
    this.onTransferTap,
    this.onAttachmentTap,
  });

  final Map<String, dynamic> row;
  final bool mine;
  final String senderName;
  final String? avatarUrl;
  final bool showDate;
  final bool showIdentity;
  final VoidCallback? onLongPress;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onReplyTap;
  final VoidCallback? onTransferTap;
  final ValueChanged<Map<String, dynamic>>? onAttachmentTap;

  @override
  Widget build(BuildContext context) {
    final created = parseChatDate(row['created_at']);
    final deleted = row['deleted_at'] != null;
    final forwarded = row['forwarded_from_id'] != null || row['message_type'] == 'forwarded';
    final edited = row['edited_at'] != null;
    final replyBody = row['reply_preview_body']?.toString();
    final receiptStatus = row['receipt_status']?.toString() ?? 'sent';
    final attachments = (row['attachments'] as List?)
            ?.whereType<Map>()
            .map((value) => Map<String, dynamic>.from(value))
            .toList() ??
        <Map<String, dynamic>>[];
    return Column(
      children: [
        if (showDate) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: softSurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Text(chatDayLabel(created), style: const TextStyle(color: mutedInk, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
        Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                if (!mine) ...[
                  SizedBox(
                    width: 32,
                    child: showIdentity
                        ? GestureDetector(
                            onTap: onAvatarTap,
                            child: EmployeeAvatar(name: senderName, imageUrl: avatarUrl, radius: 16),
                          )
                        : const SizedBox(width: 32),
                  ),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.72),
                    child: Directionality(
                      textDirection: TextDirection.rtl,
                      child: Material(
                        color: mine ? const Color(0xffdff3e8) : panelSurface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(8),
                            topRight: const Radius.circular(8),
                            bottomLeft: Radius.circular(mine ? 8 : 2),
                            bottomRight: Radius.circular(mine ? 2 : 8),
                          ),
                          side: BorderSide(color: mine ? brandColor.withValues(alpha: 0.12) : borderColor),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onLongPress: onLongPress,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (forwarded && !deleted) ...[
                                  const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.forward_rounded, size: 13, color: mutedInk),
                                      SizedBox(width: 3),
                                      Text('تم التحويل', style: TextStyle(fontSize: 9, color: mutedInk, fontStyle: FontStyle.italic)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                ],
                                if (showIdentity) ...[
                                  GestureDetector(
                                    onTap: onAvatarTap,
                                    child: Text(
                                      senderName,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        color: infoColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                ],
                                if (row['reply_to_id'] != null)
                                  ChatReplyPreview(
                                    senderName: row['reply_preview_sender']?.toString() ?? 'رسالة',
                                    body: replyBody ?? 'الرسالة الأصلية غير معروضة',
                                    onTap: onReplyTap,
                                  ),
                                if (row['reply_to_id'] != null) const SizedBox(height: 6),
                                if (deleted)
                                  const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.block_rounded, size: 16, color: mutedInk),
                                      SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          'تم حذف هذه الرسالة',
                                          style: TextStyle(height: 1.45, color: mutedInk, fontStyle: FontStyle.italic),
                                        ),
                                      ),
                                    ],
                                  )
                                else ...[
                                  if (row['transfer_order_id'] != null)
                                    TransferChatMessageCard(
                                      body: row['body']?.toString() ?? 'مناقلة مشتركة',
                                      status: row['transfer_status']?.toString(),
                                      onTap: onTransferTap,
                                    )
                                  else if ((row['body']?.toString() ?? '').isNotEmpty)
                                    Text(row['body']?.toString() ?? '', style: const TextStyle(height: 1.45)),
                                  if (attachments.isNotEmpty) ...[
                                    if ((row['body']?.toString() ?? '').isNotEmpty) const SizedBox(height: 7),
                                    ChatAttachmentList(attachments: attachments, onTap: onAttachmentTap),
                                  ],
                                ],
                                const SizedBox(height: 5),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (edited && !deleted) ...[
                                        const Text('معدّلة', style: TextStyle(fontSize: 8, color: mutedInk)),
                                        const SizedBox(width: 4),
                                      ],
                                      Text(formatTime(created), style: const TextStyle(fontSize: 9, color: mutedInk)),
                                      if (mine) ...[
                                        const SizedBox(width: 3),
                                        Icon(
                                          receiptStatus == 'sent' ? Icons.done_rounded : Icons.done_all_rounded,
                                          size: 14,
                                          color: receiptStatus == 'read' ? infoColor : brandColor,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 7),
      ],
    );
  }
}

class TransferChatMessageCard extends StatelessWidget {
  const TransferChatMessageCard({super.key, required this.body, this.status, this.onTap});

  final String body;
  final String? status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: infoColor.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: infoColor.withValues(alpha: 0.13), shape: BoxShape.circle),
                child: const Icon(Icons.swap_horiz_rounded, color: infoColor),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('مناقلة مشتركة', style: TextStyle(color: infoColor, fontWeight: FontWeight.w900, fontSize: 11)),
                    Text(body, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, height: 1.4)),
                    if (status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(statusLabel(status!), style: const TextStyle(color: brandColor, fontSize: 10, fontWeight: FontWeight.w900)),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: infoColor),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatAttachmentList extends StatelessWidget {
  const ChatAttachmentList({super.key, required this.attachments, this.onTap});

  final List<Map<String, dynamic>> attachments;
  final ValueChanged<Map<String, dynamic>>? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final attachment in attachments)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Material(
              color: softSurface,
              borderRadius: BorderRadius.circular(7),
              child: InkWell(
                onTap: onTap == null ? null : () => onTap!(attachment),
                borderRadius: BorderRadius.circular(7),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        (attachment['mime_type']?.toString() ?? '').startsWith('image/')
                            ? Icons.image_outlined
                            : Icons.description_outlined,
                        color: brandColor,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          attachment['name']?.toString() ?? 'مرفق',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
                        ),
                      ),
                      const Icon(Icons.open_in_new_rounded, color: mutedInk, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ChatReplyPreview extends StatelessWidget {
  const ChatReplyPreview({
    super.key,
    required this.senderName,
    required this.body,
    this.onTap,
  });

  final String senderName;
  final String body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: brandColor.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(9, 7, 10, 7),
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: brandColor, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: brandColor, fontSize: 10, fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: mutedInk, fontSize: 10, height: 1.35)),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatComposerContextBar extends StatelessWidget {
  const ChatComposerContextBar({
    super.key,
    required this.editing,
    required this.senderName,
    required this.body,
    required this.onClose,
  });

  final bool editing;
  final String senderName;
  final String body;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 7, 11, 7),
      decoration: BoxDecoration(
        color: softSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(color: editing ? accentColor : brandColor, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 9),
          Icon(editing ? Icons.edit_rounded : Icons.reply_rounded, size: 18, color: editing ? accentColor : brandColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: editing ? accentColor : brandColor, fontSize: 11, fontWeight: FontWeight.w900)),
                Text(body, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: mutedInk, fontSize: 10)),
              ],
            ),
          ),
          IconButton(tooltip: 'إلغاء', onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 19)),
        ],
      ),
    );
  }
}

class CreateThreadResult {
  CreateThreadResult({required this.title, required this.employeeIds, required this.isGroup});

  final String title;
  final List<String> employeeIds;
  final bool isGroup;
}

class CreateThreadPage extends StatefulWidget {
  const CreateThreadPage({
    super.key,
    required this.session,
    required this.employees,
    required this.branches,
    this.groupOnly = false,
  });

  final EmployeeSession session;
  final List<EmployeeLite> employees;
  final Map<int, BranchOption> branches;
  final bool groupOnly;

  @override
  State<CreateThreadPage> createState() => _CreateThreadPageState();
}

class _CreateThreadPageState extends State<CreateThreadPage> {
  final title = TextEditingController();
  final search = TextEditingController();
  final selected = <String>{};
  bool isGroup = false;

  @override
  void initState() {
    super.initState();
    isGroup = widget.groupOnly;
  }

  @override
  void dispose() {
    title.dispose();
    search.dispose();
    super.dispose();
  }

  void selectEmployee(EmployeeLite employee) {
    setState(() {
      if (isGroup) {
        if (!selected.add(employee.id)) selected.remove(employee.id);
      } else {
        selected
          ..clear()
          ..add(employee.id);
      }
    });
  }

  void changeMode(bool group) {
    setState(() {
      isGroup = group;
      selected.clear();
      title.clear();
    });
  }

  void submit() {
    final selectedEmployees = widget.employees.where((employee) => selected.contains(employee.id)).toList();
    if (selectedEmployees.isEmpty || (isGroup && selectedEmployees.length < 2)) return;
    final fallbackGroupTitle = selectedEmployees.take(3).map((employee) => employee.name).join('، ');
    Navigator.pop(
      context,
      CreateThreadResult(
        title: isGroup
            ? (title.text.trim().isEmpty ? fallbackGroupTitle : title.text.trim())
            : selectedEmployees.single.name,
        employeeIds: selectedEmployees.map((employee) => employee.id).toList(),
        isGroup: isGroup,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = normalizeSearch(search.text);
    final employees = widget.employees.where((employee) {
      if (employee.id == widget.session.id) return false;
      if (query.isEmpty) return true;
      return normalizeSearch(employee.name).contains(query);
    }).toList();
    final canCreate = isGroup ? selected.length >= 2 : selected.length == 1;
    return Scaffold(
      appBar: AppBar(title: Text(isGroup ? 'مجموعة جديدة' : 'محادثة جديدة')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.groupOnly)
                  Row(
                    children: [
                      Expanded(
                        child: ChatModeButton(
                          selected: !isGroup,
                          icon: Icons.person_rounded,
                          label: 'محادثة خاصة',
                          onTap: () => changeMode(false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChatModeButton(
                          selected: isGroup,
                          icon: Icons.groups_rounded,
                          label: 'مجموعة',
                          onTap: () => changeMode(true),
                        ),
                      ),
                    ],
                  ),
                if (isGroup) ...[
                  if (!widget.groupOnly) const SizedBox(height: 10),
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(
                      labelText: 'اسم المجموعة',
                      hintText: 'مثال: فريق فرع حمص',
                      prefixIcon: Icon(Icons.edit_rounded),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'ابحث عن موظف بالاسم',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'مسح البحث',
                            onPressed: () {
                              search.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      isGroup ? 'اختر شخصين على الأقل' : 'اختر موظفاً واحداً',
                      style: const TextStyle(color: mutedInk, fontSize: 12),
                    ),
                    const Spacer(),
                    if (selected.isNotEmpty)
                      StatusPill(label: '${selected.length} محدد', color: brandColor),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: employees.isEmpty
                ? const EmptyState(icon: Icons.person_search_rounded, text: 'لا يوجد موظفون مطابقون')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    itemCount: employees.length,
                    separatorBuilder: (_, __) => const Divider(indent: 64, height: 1),
                    itemBuilder: (context, index) {
                      final employee = employees[index];
                      final active = selected.contains(employee.id);
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        onTap: () => selectEmployee(employee),
                        leading: EmployeeAvatar(name: employee.name, imageUrl: employee.avatarUrl, radius: 23),
                        title: Text(employee.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          '${roleLabel(employee.role)} · ${branchLabel(widget.branches, employee.branchNum)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: mutedInk, fontSize: 11),
                        ),
                        trailing: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 27,
                          height: 27,
                          decoration: BoxDecoration(
                            color: active ? brandColor : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(color: active ? brandColor : borderColor, width: 2),
                          ),
                          child: active ? const Icon(Icons.check_rounded, color: Colors.white, size: 17) : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(
            color: panelSurface,
            border: Border(top: BorderSide(color: borderColor)),
          ),
          child: FilledButton.icon(
            onPressed: canCreate ? submit : null,
            icon: Icon(isGroup ? Icons.group_add_rounded : Icons.chat_rounded),
            label: Text(isGroup ? 'إنشاء المجموعة' : 'بدء المحادثة'),
          ),
        ),
      ),
    );
  }
}

class ChatModeButton extends StatelessWidget {
  const ChatModeButton({
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
      color: selected ? brandColor : panelSurface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? brandColor : borderColor),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: selected ? Colors.white : brandColor, size: 20),
              const SizedBox(width: 7),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(color: selected ? Colors.white : inkColor, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String employeeDisplayName(Map<String, dynamic> row) {
  return (row['display_name'] ?? row['full_name'] ?? 'موظف').toString();
}

bool canDeleteChatMessageForEveryone(Map<String, dynamic> message, EmployeeSession session) {
  return message['sender_id']?.toString() == session.id;
}

bool chatMessageSnapshotsEqual(
  List<Map<String, dynamic>>? previous,
  List<Map<String, dynamic>> current,
) {
  if (previous == null || previous.length != current.length) return false;
  const watchedKeys = [
    'id',
    'body',
    'edited_at',
    'deleted_at',
    'reply_to_id',
    'forwarded_from_id',
    'receipt_status',
    'attachments',
    'transfer_order_id',
  ];
  for (var index = 0; index < current.length; index++) {
    for (final key in watchedKeys) {
      if (previous[index][key]?.toString() != current[index][key]?.toString()) return false;
    }
  }
  return true;
}

Future<List<Map<String, dynamic>>> loadVisibleChatThreads(EmployeeSession session) async {
  final threadRows = await supabase
      .from('ansar_chat_threads')
      .select()
      .eq('is_active', true)
      .order('updated_at', ascending: false);
  final joinedRows = await supabase
      .from('ansar_chat_participants')
      .select('thread_id')
      .eq('employee_id', session.id);
  final joinedIds = joinedRows.map((row) => row['thread_id']?.toString()).whereType<String>().toSet();
  return threadRows.cast<Map<String, dynamic>>().where((thread) {
    if (thread['thread_type'] == 'general') return true;
    return joinedIds.contains(thread['id']?.toString());
  }).toList();
}

Map<String, dynamic> notificationData(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Invalid notification data is treated as an ordinary notification.
    }
  }
  return <String, dynamic>{};
}

Future<Map<String, dynamic>?> loadChatThreadForSession(
  EmployeeSession session,
  String threadId,
) async {
  final rows = await supabase
      .from('ansar_chat_threads')
      .select()
      .eq('id', threadId)
      .eq('is_active', true)
      .limit(1);
  if (rows.isEmpty) return null;
  final thread = Map<String, dynamic>.from(rows.first);
  final participantRows = await supabase
      .from('ansar_chat_participants')
      .select('employee_id')
      .eq('thread_id', threadId);
  final participantIds = participantRows
      .map((row) => row['employee_id']?.toString())
      .whereType<String>()
      .toList();
  final type = thread['thread_type']?.toString() ?? 'general';
  if (type != 'general' && !participantIds.contains(session.id)) return null;
  thread['participant_ids'] = participantIds;

  if (type == 'direct') {
    final otherIds = participantIds.where((id) => id != session.id).toList();
    if (otherIds.isNotEmpty) {
      final employeeRows = await supabase
          .from('ansar_employees')
          .select('display_name, full_name, avatar_url')
          .eq('id', otherIds.first)
          .limit(1);
      if (employeeRows.isNotEmpty) {
        final employee = employeeRows.first;
        final name = employeeDisplayName(employee);
        thread['title'] = name;
        thread['thread_avatar_name'] = name;
        thread['thread_avatar_url'] = employee['avatar_url'];
      }
    }
  }
  return thread;
}

Future<void> openChatNotification(
  BuildContext context,
  EmployeeSession session,
  Map<String, dynamic> data,
) async {
  if (!isChatNotificationType(data['type']?.toString())) return;
  final threadId = data['thread_id']?.toString();
  if (threadId == null || threadId.isEmpty) return;
  try {
    final thread = await loadChatThreadForSession(session, threadId);
    if (!context.mounted) return;
    if (thread == null) {
      showSnack(context, 'تعذر فتح المحادثة أو لم تعد متاحة لهذا الحساب');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: ChatThreadPage(session: session, thread: thread),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted) showSnack(context, cleanError(error));
  }
}

Future<void> openTransferNotification(
  BuildContext context,
  EmployeeSession session,
  Map<String, dynamic> data,
) async {
  final orderId = data['order_id']?.toString();
  if (orderId == null || orderId.isEmpty) return;
  try {
    final rows = await supabase
        .from('ansar_transfer_orders')
        .select()
        .eq('id', orderId)
        .limit(1);
    if (!context.mounted) return;
    if (rows.isEmpty) {
      showSnack(context, 'تعذر العثور على المناقلة المطلوبة');
      return;
    }
    final order = Map<String, dynamic>.from(rows.first);
    final fromBranch = nullableIntValue(order['from_branch_num']);
    final toBranch = nullableIntValue(order['to_branch_num']);
    final visible = session.isAdmin ||
        session.canManageAllBranches ||
        fromBranch == session.branchNum ||
        toBranch == session.branchNum ||
        order['requested_by']?.toString() == session.id;
    if (!visible) {
      showSnack(context, 'هذه المناقلة غير متاحة لهذا الحساب');
      return;
    }
    final branches = await loadAppBranchesMap();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: TransferDetailsPage(session: session, order: order, branches: branches),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted) showSnack(context, cleanError(error));
  }
}

Future<void> markNotificationOpened(Map<String, dynamic> data, String employeeId) async {
  final notificationId = data['notification_id']?.toString();
  if (notificationId == null || notificationId.isEmpty) return;
  try {
    await supabase.from('ansar_notification_receipts').upsert({
      'notification_id': notificationId,
      'employee_id': employeeId,
      'opened_at': DateTime.now().toUtc().toIso8601String(),
      'synced_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'notification_id,employee_id');
  } catch (_) {
    // Opening the target screen must work before the optional receipt migration is installed.
  }
}

Future<void> markChatNotificationDelivered(String employeeId, String threadId) async {
  try {
    await supabase.rpc('ansar_mark_chat_delivered', params: {
      'p_employee_id': employeeId,
      'p_thread_id': threadId,
    });
  } catch (_) {
    // Delivery receipts become available after the additive chat migration is installed.
  }
}

Future<Map<String, int>> loadChatUnreadCounts(String employeeId) async {
  try {
    final response = await supabase.rpc('ansar_chat_unread_counts', params: {
      'p_employee_id': employeeId,
    });
    if (response is List) {
      return {
        for (final item in response)
          if (item is Map && item['thread_id'] != null)
            '${item['thread_id']}': nullableIntValue(item['unread_count']) ?? 0,
      };
    }
  } catch (_) {
    // Fall back to the receipt table while the RPC migration is being deployed.
  }
  final rows = await supabase
      .from('ansar_chat_message_receipts')
      .select('thread_id')
      .eq('employee_id', employeeId)
      .neq('status', 'read');
  final counts = <String, int>{};
  for (final row in rows) {
    final threadId = '${row['thread_id']}';
    counts[threadId] = (counts[threadId] ?? 0) + 1;
  }
  return counts;
}

Future<void> touchEmployeePresence(String employeeId, {required bool online}) async {
  try {
    await supabase.from('ansar_employees').update({
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', employeeId);
  } catch (_) {
    // Presence is best effort and must not interrupt the app lifecycle.
  }
}

Future<void> openOrCreateDirectChat(
  BuildContext context,
  EmployeeSession session,
  EmployeeLite employee,
) async {
  if (employee.id == session.id) return;
  try {
    final matchingRows = await supabase
        .from('ansar_chat_participants')
        .select('thread_id, employee_id')
        .inFilter('employee_id', [session.id, employee.id]);
    final candidateIds = <String, Set<String>>{};
    for (final row in matchingRows) {
      final threadId = row['thread_id']?.toString();
      final employeeId = row['employee_id']?.toString();
      if (threadId != null && employeeId != null) {
        candidateIds.putIfAbsent(threadId, () => <String>{}).add(employeeId);
      }
    }
    final candidates = candidateIds.entries
        .where((entry) => entry.value.contains(session.id) && entry.value.contains(employee.id))
        .map((entry) => entry.key)
        .toList();
    Map<String, dynamic>? directThread;
    if (candidates.isNotEmpty) {
      final fullParticipants = await supabase
          .from('ansar_chat_participants')
          .select('thread_id, employee_id')
          .inFilter('thread_id', candidates);
      final allByThread = <String, Set<String>>{};
      for (final row in fullParticipants) {
        final threadId = row['thread_id']?.toString();
        final employeeId = row['employee_id']?.toString();
        if (threadId != null && employeeId != null) {
          allByThread.putIfAbsent(threadId, () => <String>{}).add(employeeId);
        }
      }
      final exactIds = allByThread.entries
          .where((entry) => entry.value.length == 2 && entry.value.contains(session.id) && entry.value.contains(employee.id))
          .map((entry) => entry.key)
          .toList();
      if (exactIds.isNotEmpty) {
        final rows = await supabase
            .from('ansar_chat_threads')
            .select()
            .inFilter('id', exactIds)
            .eq('thread_type', 'direct')
            .eq('is_active', true)
            .limit(1);
        if (rows.isNotEmpty) directThread = Map<String, dynamic>.from(rows.first);
      }
    }

    if (directThread == null) {
      final inserted = await supabase.from('ansar_chat_threads').insert({
        'title': employee.name,
        'thread_type': 'direct',
        'created_by': session.id,
      }).select().single();
      await supabase.from('ansar_chat_participants').insert([
        {'thread_id': inserted['id'], 'employee_id': session.id, 'role': 'admin'},
        {'thread_id': inserted['id'], 'employee_id': employee.id, 'role': 'member'},
      ]);
      directThread = Map<String, dynamic>.from(inserted);
    }

    directThread['participant_ids'] = [session.id, employee.id];
    directThread['thread_avatar_url'] = employee.avatarUrl;
    directThread['thread_avatar_name'] = employee.name;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: ChatThreadPage(session: session, thread: directThread!),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted) showSnack(context, cleanError(error));
  }
}

class ForwardMessagePage extends StatefulWidget {
  const ForwardMessagePage({super.key, required this.session, required this.sourceMessage});

  final EmployeeSession session;
  final Map<String, dynamic> sourceMessage;

  @override
  State<ForwardMessagePage> createState() => _ForwardMessagePageState();
}

class _ForwardMessagePageState extends State<ForwardMessagePage> {
  final search = TextEditingController();
  final selected = <String>{};
  late final Future<List<Map<String, dynamic>>> future;
  bool sending = false;

  @override
  void initState() {
    super.initState();
    future = loadVisibleChatThreads(widget.session);
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (selected.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final body = widget.sourceMessage['body']?.toString() ?? '';
      await supabase.from('ansar_chat_messages').insert(
            selected
                .map((threadId) => {
                      'thread_id': threadId,
                      'sender_id': widget.session.id,
                      'body': body,
                      'message_type': 'forwarded',
                      'forwarded_from_id': '${widget.sourceMessage['id']}',
                    })
                .toList(),
          );
      final now = DateTime.now().toUtc().toIso8601String();
      final threads = await loadVisibleChatThreads(widget.session);
      for (final threadId in selected) {
        unawaited(supabase.from('ansar_chat_threads').update({'updated_at': now}).eq('id', threadId));
        Map<String, dynamic>? thread;
        for (final item in threads) {
          if ('${item['id']}' == threadId) {
            thread = item;
            break;
          }
        }
        if (thread != null) {
          unawaited(enqueueChatNotification(thread: thread, sender: widget.session, body: body));
        }
      }
      if (mounted) Navigator.pop(context, selected.length);
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تحويل الرسالة')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: () {});
          final query = normalizeSearch(search.text);
          final threads = snapshot.data!
              .where((thread) => query.isEmpty || normalizeSearch(thread['title']?.toString() ?? '').contains(query))
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: 'ابحث عن محادثة', prefixIcon: Icon(Icons.search_rounded)),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                  itemCount: threads.length,
                  separatorBuilder: (_, __) => const Divider(indent: 64),
                  itemBuilder: (context, index) {
                    final thread = threads[index];
                    final id = '${thread['id']}';
                    final active = selected.contains(id);
                    return ListTile(
                      onTap: () => setState(() => active ? selected.remove(id) : selected.add(id)),
                      leading: CircleAvatar(
                        backgroundColor: successSurface,
                        child: Icon(thread['thread_type'] == 'group' ? Icons.groups_rounded : Icons.chat_rounded, color: brandColor),
                      ),
                      title: Text(thread['title']?.toString() ?? 'محادثة', style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(chatTypeLabel(thread['thread_type']?.toString() ?? 'general')),
                      trailing: Icon(active ? Icons.check_circle_rounded : Icons.circle_outlined, color: active ? brandColor : mutedInk),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: FilledButton.icon(
            onPressed: selected.isEmpty || sending ? null : submit,
            icon: sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.forward_rounded),
            label: Text(selected.isEmpty ? 'اختر محادثة' : 'تحويل إلى ${selected.length}'),
          ),
        ),
      ),
    );
  }
}

Future<void> openEmployeePublicProfile(
  BuildContext context,
  EmployeeSession session,
  String employeeId,
) async {
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: EmployeePublicProfilePage(session: session, employeeId: employeeId),
      ),
    ),
  );
}

class EmployeePublicProfilePage extends StatefulWidget {
  const EmployeePublicProfilePage({super.key, required this.session, required this.employeeId});

  final EmployeeSession session;
  final String employeeId;

  @override
  State<EmployeePublicProfilePage> createState() => _EmployeePublicProfilePageState();
}

class _EmployeePublicProfilePageState extends State<EmployeePublicProfilePage> {
  late Future<Map<String, dynamic>> future = loadProfile();

  Future<Map<String, dynamic>> loadProfile() async {
    try {
      final response = await supabase.rpc('ansar_employee_public_profile', params: {
        'p_employee_id': widget.employeeId,
      });
      if (response is Map && response.isNotEmpty) return Map<String, dynamic>.from(response);
    } catch (_) {
      // Use the same public field list while the RPC migration is being installed.
    }
    final rows = await supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, avatar_url, phone, email, job_title, branch_num, role, last_seen_at')
        .eq('id', widget.employeeId)
        .eq('is_active', true)
        .limit(1);
    if (rows.isEmpty) throw Exception('تعذر العثور على بيانات الموظف');
    final row = Map<String, dynamic>.from(rows.first);
    try {
      final branches = await loadAppBranchesMap();
      row['branch_name'] = branchLabel(branches, nullableIntValue(row['branch_num']) ?? 0);
    } catch (_) {
      // The branch number remains available if the branch lookup is offline.
    }
    return row;
  }

  Future<void> showAvatar(Map<String, dynamic> profile) async {
    final url = profile['avatar_url']?.toString();
    if (url == null || url.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Image.network(url, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  tooltip: 'إغلاق',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> startChat(Map<String, dynamic> profile) async {
    if (widget.employeeId == widget.session.id) return;
    await openOrCreateDirectChat(
      context,
      widget.session,
      EmployeeLite(
        id: widget.employeeId,
        name: employeeDisplayName(profile),
        username: '',
        branchNum: nullableIntValue(profile['branch_num']) ?? 0,
        role: profile['role']?.toString() ?? 'employee',
        isActive: true,
        avatarUrl: profile['avatar_url']?.toString(),
      ),
    );
  }

  Future<void> launchContact(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      showSnack(context, 'لا يوجد تطبيق مناسب لتنفيذ هذا الإجراء');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('معلومات الموظف')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: cleanError(snapshot.error),
              onRetry: () => setState(() => future = loadProfile()),
            );
          }
          final profile = snapshot.data!;
          final name = employeeDisplayName(profile);
          final avatarUrl = profile['avatar_url']?.toString();
          final phone = profile['phone']?.toString().trim() ?? '';
          final email = profile['email']?.toString().trim() ?? '';
          final jobTitle = profile['job_title']?.toString().trim() ?? '';
          final branch = profile['branch_name']?.toString().trim().isNotEmpty == true
              ? profile['branch_name'].toString()
              : 'فرع رقم ${profile['branch_num'] ?? '-'}';
          final lastSeen = DateTime.tryParse(profile['last_seen_at']?.toString() ?? '')?.toLocal();
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 32),
            children: [
              Center(
                child: GestureDetector(
                  onTap: avatarUrl == null || avatarUrl.isEmpty ? null : () => showAvatar(profile),
                  child: Hero(
                    tag: 'employee-avatar-${widget.employeeId}',
                    child: EmployeeAvatar(name: name, imageUrl: avatarUrl, radius: 58),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              Text(
                [if (jobTitle.isNotEmpty) jobTitle, branch].join(' · '),
                textAlign: TextAlign.center,
                style: const TextStyle(color: mutedInk),
              ),
              if (lastSeen != null)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text('آخر ظهور ${formatDateTime(lastSeen)}', textAlign: TextAlign.center, style: const TextStyle(color: mutedInk, fontSize: 12)),
                ),
              if (widget.employeeId != widget.session.id) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => startChat(profile),
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: const Text('بدء محادثة خاصة'),
                ),
              ],
              const SizedBox(height: 18),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.badge_outlined, color: brandColor),
                      title: const Text('المسمى الوظيفي'),
                      subtitle: Text(jobTitle.isEmpty ? 'غير محدد' : jobTitle),
                    ),
                    const Divider(indent: 58),
                    ListTile(
                      leading: const Icon(Icons.storefront_outlined, color: brandColor),
                      title: const Text('الفرع'),
                      subtitle: Text(branch),
                    ),
                    if (phone.isNotEmpty) ...[
                      const Divider(indent: 58),
                      ListTile(
                        onTap: () => launchContact(Uri(scheme: 'tel', path: phone)),
                        leading: const Icon(Icons.phone_outlined, color: infoColor),
                        title: const Text('الهاتف'),
                        subtitle: Text(phone),
                        trailing: const Icon(Icons.call_rounded, color: infoColor),
                      ),
                    ],
                    if (email.isNotEmpty) ...[
                      const Divider(indent: 58),
                      ListTile(
                        onTap: () => launchContact(Uri(scheme: 'mailto', path: email)),
                        leading: const Icon(Icons.email_outlined, color: accentColor),
                        title: const Text('البريد الإلكتروني'),
                        subtitle: Text(email),
                        trailing: const Icon(Icons.open_in_new_rounded, color: mutedInk),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ChatInfoResult {
  const ChatInfoResult({this.title, this.leftThread = false});

  final String? title;
  final bool leftThread;
}

class ChatInfoPage extends StatefulWidget {
  const ChatInfoPage({super.key, required this.session, required this.thread});

  final EmployeeSession session;
  final Map<String, dynamic> thread;

  @override
  State<ChatInfoPage> createState() => _ChatInfoPageState();
}

class _ChatInfoPageState extends State<ChatInfoPage> {
  late Future<List<Map<String, dynamic>>> future;
  late String currentTitle;
  late String currentDescription;

  String get threadId => '${widget.thread['id']}';
  String get threadType => widget.thread['thread_type']?.toString() ?? 'general';
  bool get isGroup => threadType == 'group';

  @override
  void initState() {
    super.initState();
    currentTitle = widget.thread['title']?.toString() ?? 'محادثة';
    currentDescription = widget.thread['description']?.toString() ?? '';
    future = loadParticipants();
  }

  Future<List<Map<String, dynamic>>> loadParticipants() async {
    final rows = await supabase
        .from('ansar_chat_participants')
        .select()
        .eq('thread_id', threadId);
    final participantRows = rows.cast<Map<String, dynamic>>().toList();
    if (threadType == 'general' && !participantRows.any((row) => '${row['employee_id']}' == widget.session.id)) {
      try {
        await supabase.from('ansar_chat_participants').upsert({
          'thread_id': threadId,
          'employee_id': widget.session.id,
          'role': 'member',
        }, onConflict: 'thread_id,employee_id');
        participantRows.add({
          'thread_id': threadId,
          'employee_id': widget.session.id,
          'role': 'member',
          'is_muted': false,
        });
      } catch (_) {
        // Older installations may not register general-chat participants yet.
      }
    }
    final ids = participantRows.map((row) => row['employee_id']?.toString()).whereType<String>().toList();
    final employeeQuery = supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, branch_num, role, is_active, avatar_url, last_seen_at');
    final employeeRows = threadType == 'general'
        ? await employeeQuery.eq('is_active', true)
        : ids.isEmpty
            ? <Map<String, dynamic>>[]
            : await employeeQuery.inFilter('id', ids);
    final employees = {
      for (final row in employeeRows.cast<Map<String, dynamic>>()) '${row['id']}': row,
    };
    final participantsByEmployee = {
      for (final row in participantRows) '${row['employee_id']}': row,
    };
    final sourceParticipants = threadType == 'general'
        ? employees.keys
            .map((employeeId) => participantsByEmployee[employeeId] ?? <String, dynamic>{
                  'thread_id': threadId,
                  'employee_id': employeeId,
                  'role': 'member',
                  'is_muted': false,
                })
            .toList()
        : participantRows;
    return sourceParticipants.map((participant) {
      final employee = employees['${participant['employee_id']}'];
      return {
        ...participant,
        if (employee != null) ...employee,
        'participant_role': participant['role']?.toString() ?? 'member',
      };
    }).toList()
      ..sort((a, b) {
        final aAdmin = a['participant_role'] == 'admin' ? 0 : 1;
        final bAdmin = b['participant_role'] == 'admin' ? 0 : 1;
        if (aAdmin != bAdmin) return aAdmin.compareTo(bAdmin);
        return employeeDisplayName(a).compareTo(employeeDisplayName(b));
      });
  }

  Map<String, dynamic>? currentParticipant(List<Map<String, dynamic>> participants) {
    for (final participant in participants) {
      if ('${participant['employee_id']}' == widget.session.id) return participant;
    }
    return null;
  }

  bool canManage(List<Map<String, dynamic>> participants) {
    final participant = currentParticipant(participants);
    return widget.session.isAdmin ||
        widget.thread['created_by'] == widget.session.id ||
        participant?['participant_role'] == 'admin';
  }

  void reload() {
    if (mounted) setState(() => future = loadParticipants());
  }

  Future<void> editTitle() async {
    final controller = TextEditingController(text: currentTitle);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('اسم المجموعة'),
        content: TextField(controller: controller, autofocus: true, maxLength: 80),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('حفظ')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    try {
      await supabase.from('ansar_chat_threads').update({'title': value}).eq('id', threadId);
      setState(() => currentTitle = value);
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    }
  }

  Future<void> editDescription() async {
    final controller = TextEditingController(text: currentDescription);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('وصف المجموعة'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 180,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'اكتب وصفاً مختصراً للمجموعة'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('حفظ')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    try {
      await supabase.from('ansar_chat_threads').update({'description': value}).eq('id', threadId);
      setState(() => currentDescription = value);
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    }
  }

  Future<void> toggleMute(Map<String, dynamic>? participant, bool value) async {
    if (participant == null) return;
    try {
      await supabase
          .from('ansar_chat_participants')
          .update({
            'is_muted': value,
            'muted_until': value ? DateTime.utc(9999, 12, 31).toIso8601String() : null,
          })
          .eq('thread_id', threadId)
          .eq('employee_id', widget.session.id);
      reload();
    } catch (error) {
      if (mounted) showSnack(context, chatUpgradeError(error));
    }
  }

  Future<void> addMembers(List<Map<String, dynamic>> participants) async {
    final existingIds = participants.map((row) => '${row['employee_id']}').toSet();
    final employees = (await loadAllActiveEmployees()).where((employee) => !existingIds.contains(employee.id)).toList();
    if (!mounted) return;
    final selected = await Navigator.of(context).push<List<EmployeeLite>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: SelectChatMembersPage(title: 'إضافة أعضاء', employees: employees),
        ),
      ),
    );
    if (selected == null || selected.isEmpty) return;
    try {
      await supabase.from('ansar_chat_participants').insert(
            selected
                .map((employee) => {'thread_id': threadId, 'employee_id': employee.id, 'role': 'member'})
                .toList(),
          );
      final ids = (widget.thread['participant_ids'] as List?)?.map((value) => '$value').toSet() ?? <String>{};
      ids.addAll(selected.map((employee) => employee.id));
      widget.thread['participant_ids'] = ids.toList();
      reload();
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    }
  }

  Future<void> removeMember(Map<String, dynamic> participant) async {
    final name = employeeDisplayName(participant);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('إزالة $name؟'),
        content: const Text('لن يتمكن الموظف من فتح هذه المجموعة بعد إزالته.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('إزالة')),
        ],
      ),
    );
    if (confirmed != true) return;
    await supabase
        .from('ansar_chat_participants')
        .delete()
        .eq('thread_id', threadId)
        .eq('employee_id', participant['employee_id']);
    final ids = (widget.thread['participant_ids'] as List?)?.map((value) => '$value').toSet() ?? <String>{};
    ids.remove('${participant['employee_id']}');
    widget.thread['participant_ids'] = ids.toList();
    reload();
  }

  Future<void> leaveThread() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('مغادرة المحادثة؟'),
        content: const Text('لن تظهر لك الرسائل الجديدة بعد المغادرة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: dangerColor),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('مغادرة'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await supabase
        .from('ansar_chat_participants')
        .delete()
        .eq('thread_id', threadId)
        .eq('employee_id', widget.session.id);
    if (mounted) Navigator.pop(context, const ChatInfoResult(leftThread: true));
  }

  Future<void> openMember(Map<String, dynamic> row) async {
    await openEmployeePublicProfile(context, widget.session, '${row['employee_id']}');
  }

  Future<void> messageMember(Map<String, dynamic> row) async {
    final employee = EmployeeLite.fromRow({...row, 'id': row['employee_id'], 'username': ''});
    await openOrCreateDirectChat(context, widget.session, employee);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('معلومات المحادثة'),
        leading: IconButton(
          tooltip: 'رجوع',
          onPressed: () => Navigator.pop(context, ChatInfoResult(title: currentTitle)),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return ErrorState(message: chatUpgradeError(snapshot.error), onRetry: reload);
          }
          final participants = snapshot.data ?? <Map<String, dynamic>>[];
          final mine = currentParticipant(participants);
          final manager = canManage(participants);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
            children: [
              Center(
                child: threadType == 'direct'
                    ? EmployeeAvatar(
                        name: widget.thread['thread_avatar_name']?.toString() ?? currentTitle,
                        imageUrl: widget.thread['thread_avatar_url']?.toString(),
                        radius: 44,
                      )
                    : Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(color: successSurface, shape: BoxShape.circle, border: Border.all(color: borderColor)),
                        child: Icon(isGroup ? Icons.groups_rounded : Icons.forum_rounded, color: brandColor, size: 42),
                      ),
              ),
              const SizedBox(height: 12),
              Text(currentTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              Text(chatTypeLabel(threadType), textAlign: TextAlign.center, style: const TextStyle(color: mutedInk)),
              if (currentDescription.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(currentDescription, textAlign: TextAlign.center, style: const TextStyle(color: mutedInk, height: 1.45)),
                ),
              const SizedBox(height: 18),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: mine == null ? false : chatParticipantIsMuted(mine),
                      onChanged: mine == null ? null : (value) => toggleMute(mine, value),
                      secondary: const Icon(Icons.notifications_off_outlined),
                      title: const Text('كتم الإشعارات'),
                      subtitle: const Text('إيقاف إشعارات هذه المحادثة فقط'),
                    ),
                    if (isGroup && manager) ...[
                      const Divider(),
                      ListTile(
                        onTap: editTitle,
                        leading: const Icon(Icons.edit_rounded, color: brandColor),
                        title: const Text('تعديل اسم المجموعة'),
                        trailing: const Icon(Icons.chevron_left_rounded),
                      ),
                      const Divider(),
                      ListTile(
                        onTap: editDescription,
                        leading: const Icon(Icons.subject_rounded, color: brandColor),
                        title: const Text('وصف المجموعة'),
                        subtitle: Text(currentDescription.isEmpty ? 'أضف وصفاً للمجموعة' : currentDescription, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_left_rounded),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SectionHeader(
                title: 'الأعضاء (${participants.length})',
                action: isGroup && manager
                    ? IconButton.filledTonal(tooltip: 'إضافة أعضاء', onPressed: () => addMembers(participants), icon: const Icon(Icons.person_add_alt_1_rounded))
                    : null,
              ),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: panelSurface, borderRadius: BorderRadius.circular(8), border: Border.all(color: borderColor)),
                child: Column(
                  children: [
                    for (var index = 0; index < participants.length; index++) ...[
                      Builder(builder: (context) {
                        final participant = participants[index];
                        final isMe = '${participant['employee_id']}' == widget.session.id;
                        final lastSeen = DateTime.tryParse(participant['last_seen_at']?.toString() ?? '')?.toLocal();
                        final memberRole = participant['participant_role'] == 'admin'
                            ? 'مشرف المجموعة'
                            : roleLabel(participant['role']?.toString() ?? 'employee');
                        return ListTile(
                          onTap: isMe ? null : () => openMember(participant),
                          leading: EmployeeAvatar(
                            name: employeeDisplayName(participant),
                            imageUrl: participant['avatar_url']?.toString(),
                            radius: 22,
                          ),
                          title: Text(isMe ? '${employeeDisplayName(participant)} (أنت)' : employeeDisplayName(participant), style: const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: Text(
                            lastSeen == null ? memberRole : '$memberRole · آخر ظهور ${formatDateTime(lastSeen)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isGroup && manager && !isMe
                              ? PopupMenuButton<String>(
                                  tooltip: 'خيارات العضو',
                                  onSelected: (value) {
                                    if (value == 'chat') unawaited(messageMember(participant));
                                    if (value == 'remove') unawaited(removeMember(participant));
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'chat', child: Text('مراسلة الموظف')),
                                    PopupMenuItem(value: 'remove', child: Text('إزالة من المجموعة')),
                                  ],
                                )
                              : (!isMe
                                  ? IconButton(
                                      tooltip: 'مراسلة الموظف',
                                      onPressed: () => messageMember(participant),
                                      icon: const Icon(Icons.chat_bubble_outline_rounded, color: brandColor),
                                    )
                                  : null),
                        );
                      }),
                      if (index != participants.length - 1) const Divider(indent: 64),
                    ],
                  ],
                ),
              ),
              if (threadType != 'general') ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: dangerColor),
                  onPressed: leaveThread,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('مغادرة المحادثة'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class SelectChatMembersPage extends StatefulWidget {
  const SelectChatMembersPage({super.key, required this.title, required this.employees});

  final String title;
  final List<EmployeeLite> employees;

  @override
  State<SelectChatMembersPage> createState() => _SelectChatMembersPageState();
}

class _SelectChatMembersPageState extends State<SelectChatMembersPage> {
  final search = TextEditingController();
  final selected = <String>{};

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = normalizeSearch(search.text);
    final employees = widget.employees
        .where((employee) => query.isEmpty || normalizeSearch(employee.name).contains(query))
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'ابحث عن موظف', prefixIcon: Icon(Icons.search_rounded)),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: employees.length,
              separatorBuilder: (_, __) => const Divider(indent: 66),
              itemBuilder: (context, index) {
                final employee = employees[index];
                final active = selected.contains(employee.id);
                return ListTile(
                  onTap: () => setState(() => active ? selected.remove(employee.id) : selected.add(employee.id)),
                  leading: EmployeeAvatar(name: employee.name, imageUrl: employee.avatarUrl, radius: 23),
                  title: Text(employee.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text('${roleLabel(employee.role)} · فرع رقم ${employee.branchNum}'),
                  trailing: Icon(active ? Icons.check_circle_rounded : Icons.circle_outlined, color: active ? brandColor : mutedInk),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: FilledButton.icon(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(
                      context,
                      widget.employees.where((employee) => selected.contains(employee.id)).toList(),
                    ),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(selected.isEmpty ? 'اختر أعضاء' : 'إضافة ${selected.length}'),
          ),
        ),
      ),
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
    final number = nullableIntValue(row['sto_num']);
    if (number == null) continue;
    branches[number] = BranchOption(
      number: number,
      name: (row['name'] ?? 'فرع $number').toString(),
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
      final number = nullableIntValue(row['sto_num']);
      if (number == null) continue;
      if (row['is_active'] == false) {
        branches.remove(number);
      } else {
        branches[number] = BranchOption(
          number: number,
          name: (row['name'] ?? 'فرع $number').toString(),
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
  final cache = ProductSearchCache.instance;
  if (!await cache.hasData) await cache.synchronize(supabase, force: true);
  return cache.allProducts();
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
  final cache = ProductSearchCache.instance;
  if (!await cache.hasData) await cache.synchronize(supabase, force: true);
  return cache.allBarcodes();
}

Future<void> warmProductSearchCache() async {
  final cache = ProductSearchCache.instance;
  await cache.database;
  if (!await cache.hasData) {
    await cache.synchronize(supabase, force: true);
  } else {
    unawaited(cache.synchronize(supabase).catchError((_) {}));
  }
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
  final cache = ProductSearchCache.instance;
  var hadLocalData = false;
  var localRows = <Map<String, dynamic>>[];
  Object? localCacheError;
  try {
    hadLocalData = await cache.hasData;
    localRows = await cache.search(query, limit: max(250, limit * 8));
  } catch (error) {
    localCacheError = error;
  }
  if (localRows.isNotEmpty) {
    unawaited(cache.synchronize(supabase).catchError((_) {}));
    final localBarcodes = <int, String>{};
    for (final product in localRows) {
      final matNum = nullableIntValue(product['mat_num']);
      final barcode = product['_cached_barcode']?.toString();
      if (matNum != null && barcode != null && barcode.isNotEmpty) localBarcodes[matNum] = barcode;
    }
    return rankProductRows(localRows, query, localBarcodes, limit: limit);
  }

  Object? directError;
  try {
    final direct = await searchProductsDirect(query, limit: limit);
    if (direct.isNotEmpty) {
      unawaited(cache.synchronize(supabase, force: true).catchError((_) {}));
      return direct;
    }
  } catch (error) {
    directError = error;
  }

  try {
    await cache.synchronize(supabase, force: true);
    final refreshed = await cache.search(query, limit: max(250, limit * 8));
    final refreshedBarcodes = <int, String>{};
    for (final product in refreshed) {
      final matNum = nullableIntValue(product['mat_num']);
      final barcode = product['_cached_barcode']?.toString();
      if (matNum != null && barcode != null && barcode.isNotEmpty) refreshedBarcodes[matNum] = barcode;
    }
    return rankProductRows(refreshed, query, refreshedBarcodes, limit: limit);
  } catch (_) {
    if (hadLocalData) return <Map<String, dynamic>>[];
    if (directError != null) throw directError;
    if (localCacheError != null) throw localCacheError;
    rethrow;
  }
}

Future<List<Map<String, dynamic>>> searchProductsDirect(
  String query, {
  required int limit,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return <Map<String, dynamic>>[];
  final numeric = int.tryParse(trimmed);
  final collected = <Map<String, dynamic>>[];
  final directBarcodes = <int, String>{};

  if (numeric != null) {
    final exactRows = await supabase.from('products').select().eq('mat_num', numeric).limit(limit);
    collected.addAll(exactRows.cast<Map<String, dynamic>>());

    try {
      final barcodeRows = await supabase
          .from('product_barcodes')
          .select('mat_num, barcode')
          .ilike('barcode', '%${safeSearchPattern(trimmed)}%')
          .limit(limit);
      final barcodeMatNums = barcodeRows
          .map((row) {
            final matNum = nullableIntValue(row['mat_num']);
            if (matNum != null) directBarcodes[matNum] = row['barcode']?.toString() ?? '';
            return matNum;
          })
          .whereType<int>()
          .toSet()
          .toList();
      if (barcodeMatNums.isNotEmpty) {
        final barcodeProducts = await supabase.from('products').select().inFilter('mat_num', barcodeMatNums).limit(limit);
        collected.addAll(barcodeProducts.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // Material-number results should survive an unavailable barcode table.
    }
  } else {
    final words = trimmed
        .split(RegExp(r'\s+'))
        .map(safeSearchPattern)
        .where((word) => word.isNotEmpty)
        .take(6)
        .toList();
    if (words.isEmpty) return <Map<String, dynamic>>[];
    dynamic request = supabase.from('products').select();
    for (final word in words) {
      request = request.ilike('name', '%$word%');
    }
    final rows = await request.limit(limit * 2);
    collected.addAll((rows as List).cast<Map<String, dynamic>>());
  }

  return rankProductRows(
    deduplicateProducts(collected),
    query,
    {...?cachedBarcodes, ...directBarcodes},
    limit: limit,
  );
}

String safeSearchPattern(String value) {
  return value.replaceAll('%', '').replaceAll('_', '').trim();
}

List<Map<String, dynamic>> deduplicateProducts(Iterable<Map<String, dynamic>> products) {
  final unique = <int, Map<String, dynamic>>{};
  for (final product in products) {
    final matNum = nullableIntValue(product['mat_num']);
    if (matNum != null) unique.putIfAbsent(matNum, () => product);
  }
  return unique.values.toList();
}

List<Map<String, dynamic>> rankProductRows(
  Iterable<Map<String, dynamic>> products,
  String query,
  Map<int, String> barcodes, {
  required int limit,
}) {
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
  final matNum = nullableIntValue(product['mat_num']);
  final matText = matNum?.toString() ?? '';
  final name = normalizeSearch(product['name']?.toString() ?? '');
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
  return normalizeProductSearch(value);
}

Future<List<EmployeeLite>> loadEmployeesForScope(
  EmployeeSession session, {
  required bool includeInactive,
}) async {
  var query = supabase
      .from('ansar_employees')
      .select('id, display_name, full_name, username, branch_num, role, is_active, avatar_url, can_manage_all_branches');
  if (!includeInactive) query = query.eq('is_active', true);
  if (!session.isAdmin && session.isBranchManager) {
    query = query.eq('branch_num', session.branchNum);
  } else if (!session.isAdmin) {
    query = query.eq('id', session.id);
  }
  final rows = await query.order('display_name', ascending: true);
  return rows.map(EmployeeLite.fromRow).toList();
}

Future<List<EmployeeLite>> loadAllActiveEmployees() async {
  final rows = await supabase
      .from('ansar_employees')
      .select('id, display_name, full_name, branch_num, role, is_active, avatar_url, can_manage_all_branches')
      .eq('is_active', true)
      .order('display_name', ascending: true);
  return rows.cast<Map<String, dynamic>>().map(EmployeeLite.fromRow).toList();
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
    case 'received':
      return 'تم الاستلام';
    case 'rejected':
      return 'مرفوض';
    case 'cancelled':
      return 'ملغي';
    default:
      return status;
  }
}

List<String> transferAllowedNextStatuses(String current) {
  switch (current) {
    case 'submitted':
      return const ['approved', 'partially_available', 'rejected', 'cancelled'];
    case 'approved':
      return const ['partially_available', 'preparing', 'rejected', 'cancelled'];
    case 'partially_available':
      return const ['preparing', 'rejected', 'cancelled'];
    case 'preparing':
      return const ['in_delivery', 'cancelled'];
    default:
      return const [];
  }
}

Future<bool> transferItemsReadyForDelivery(String orderId) async {
  final rows = await supabase
      .from('ansar_transfer_order_items')
      .select('item_status, approved_quantity')
      .eq('order_id', orderId);
  if (rows.isEmpty) return false;
  return rows.every((row) {
    final status = row['item_status']?.toString() ?? 'requested';
    return status != 'requested' && row['approved_quantity'] != null;
  });
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
    case 'received':
      return Icons.inventory_rounded;
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
    case 'received':
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
  'received',
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
    case 'received':
      return 'المستلمة';
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
  String? notificationKey,
  Map<String, Object?> data = const {},
}) async {
  try {
    final unifiedData = <String, Object?>{
      ...data,
      'route': data['route'] ?? notificationRouteForType(data['type']?.toString() ?? ''),
    };
    await supabase.from('ansar_notification_queue').insert({
      if (employeeId != null) 'employee_id': employeeId,
      if (branchNum != null) 'branch_num': branchNum,
      'title': title,
      'body': body,
      'data': unifiedData,
      'status': 'pending',
      if (notificationKey != null) 'notification_key': notificationKey,
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
    final unifiedData = <String, Object?>{
      ...data,
      'route': data['route'] ?? notificationRouteForType(data['type']?.toString() ?? ''),
    };
    await supabase.from('ansar_notification_queue').insert(
          ids
              .map((id) => {
                    'employee_id': id,
                    'title': title,
                    'body': body,
                    'data': unifiedData,
                    'status': 'pending',
                  })
              .toList(),
        );
    unawaited(kickNotificationSender());
  } catch (_) {
    // Notifications are helpful, but core workflow should not fail if queue policies are not ready.
  }
}

String notificationRouteForType(String type) {
  if (type.contains('chat')) return 'chat';
  if (type.contains('transfer')) return 'transfer';
  if (type.contains('attendance')) return 'attendance';
  return 'home';
}

bool isChatNotificationType(String? type) => type?.startsWith('chat') == true;

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
  final title = type == 'general' ? '${sender.name} في الدردشة العامة' : 'رسالة جديدة من ${sender.name}';
  final data = {
    'type': 'chat_message',
    'thread_id': threadId,
    'sender_id': sender.id,
    'sender_name': sender.name,
    'sender_avatar_url': sender.avatarUrl ?? '',
    'message_preview': body,
    'thread_title': thread['title']?.toString() ?? '',
    'thread_type': type,
  };

  List<Map<String, dynamic>> participants;
  try {
    final rows = await supabase
        .from('ansar_chat_participants')
        .select('employee_id, is_muted, muted_until')
        .eq('thread_id', threadId)
        .neq('employee_id', sender.id);
    participants = rows.cast<Map<String, dynamic>>();
  } catch (_) {
    final rows = await supabase
        .from('ansar_chat_participants')
        .select('employee_id')
        .eq('thread_id', threadId)
        .neq('employee_id', sender.id);
    participants = rows.cast<Map<String, dynamic>>();
  }
  if (type == 'general') {
    final mutedIds = participants
        .where(chatParticipantIsMuted)
        .map((row) => row['employee_id']?.toString())
        .whereType<String>()
        .toSet();
    final employees = await supabase
        .from('ansar_employees')
        .select('id')
        .eq('is_active', true)
        .neq('id', sender.id);
    await enqueueNotificationsForEmployees(
      employeeIds: employees
          .map((row) => row['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty && !mutedIds.contains(id)),
      title: title,
      body: body,
      data: data,
    );
    return;
  }
  await enqueueNotificationsForEmployees(
    employeeIds: participants
        .where((row) => !chatParticipantIsMuted(row))
        .map((row) => row['employee_id']?.toString() ?? ''),
    title: title,
    body: body,
    data: data,
  );
}

bool chatParticipantIsMuted(Map<String, dynamic> row) {
  if (row['is_muted'] != true) return false;
  final until = DateTime.tryParse(row['muted_until']?.toString() ?? '')?.toUtc();
  return until == null || until.isAfter(DateTime.now().toUtc());
}

Future<void> registerDeviceForNotifications(EmployeeSession session) async {
  final messaging = FirebaseMessaging.instance;
  final installationId = await stableInstallationId();
  final sessionPreferences = await SharedPreferences.getInstance();
  await sessionPreferences.setString('ansar_employee_id', session.id);
  String? fcmToken;
  String? pushyToken;
  Object? firebaseError;
  Object? pushyError;
  var permissionStatus = 'unknown';
  lastNotificationRegistrationError = null;

  try {
    await messaging.setAutoInitEnabled(true);
    final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
    permissionStatus = settings.authorizationStatus.name;
    if (settings.authorizationStatus != AuthorizationStatus.denied) {
      fcmToken = await getMessagingTokenWithRecovery(messaging);
    }
  } catch (error) {
    firebaseError = error;
  }

  try {
    Pushy.listen();
    final token = await Pushy.register();
    if (token.isNotEmpty) {
      pushyToken = token;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('ansar_pushy_token', token);
    }
  } catch (error) {
    pushyError = error;
    final preferences = await SharedPreferences.getInstance();
    pushyToken = preferences.getString('ansar_pushy_token');
  }

  try {
    await saveDeviceInstallation(
      session,
      installationId: installationId,
      permissionStatus: permissionStatus,
      fcmToken: fcmToken,
      pushyToken: pushyToken,
    );
    if (fcmToken != null) await saveLegacyFirebaseToken(session, fcmToken);
    await notificationTokenRefreshSubscription?.cancel();
    notificationTokenRefreshSubscription = messaging.onTokenRefresh.listen((newToken) async {
      await saveDeviceInstallation(
        session,
        installationId: installationId,
        permissionStatus: permissionStatus,
        fcmToken: newToken,
      );
      await saveLegacyFirebaseToken(session, newToken);
    });

    if (permissionStatus == AuthorizationStatus.denied.name) {
      throw Exception('الإشعارات مرفوضة من إعدادات الهاتف. فعّل الإذن حتى تظهر خارج التطبيق.');
    }
    if (fcmToken == null && pushyToken == null) {
      throw Exception('تعذر تسجيل Firebase وPushy لهذا الجهاز');
    }
  } catch (error) {
    final sourceError = firebaseError ?? pushyError ?? error;
    lastNotificationRegistrationError = isTemporaryMessagingServiceError(sourceError)
        ? 'خدمة إشعارات الهاتف غير متاحة مؤقتاً، سيحاول التطبيق تلقائياً'
        : cleanError(error);
    lastNotificationRegistrationAt = DateTime.now();
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
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('ansar_pushy_token');
    await registerDeviceForNotifications(session);
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
  await saveDeviceInstallation(
    session,
    installationId: await stableInstallationId(),
    permissionStatus: 'authorized',
    fcmToken: token,
  );
  await saveLegacyFirebaseToken(session, token);
}

Future<String> stableInstallationId() async {
  final preferences = await SharedPreferences.getInstance();
  final existing = preferences.getString('ansar_installation_id');
  if (existing != null && existing.isNotEmpty) return existing;
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  final id = base64Url.encode(bytes).replaceAll('=', '');
  await preferences.setString('ansar_installation_id', id);
  return id;
}

Future<void> saveDeviceInstallation(
  EmployeeSession session, {
  required String installationId,
  required String permissionStatus,
  String? fcmToken,
  String? pushyToken,
}) async {
  String appVersion = '0.4.1+8';
  try {
    final info = await PackageInfo.fromPlatform();
    appVersion = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // Keep the declared package version when platform metadata is unavailable.
  }
  final values = <String, Object?>{
    'installation_id': installationId,
    'employee_id': session.id,
    'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
    'device_name': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'app_version': appVersion,
    'notification_capabilities': const {
      'rich_notifications_v1': true,
      'inline_reply_v1': true,
      'notification_deduplication_v1': true,
    },
    'permission_status': permissionStatus,
    'is_active': (fcmToken?.isNotEmpty ?? false) || (pushyToken?.isNotEmpty ?? false),
    'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    'updated_at': DateTime.now().toUtc().toIso8601String(),
    if (fcmToken != null && fcmToken.isNotEmpty) 'fcm_token': fcmToken,
    if (pushyToken != null && pushyToken.isNotEmpty) 'pushy_token': pushyToken,
  };
  try {
    if (fcmToken != null && fcmToken.isNotEmpty) {
      await supabase
          .from('ansar_device_installations')
          .update({'fcm_token': null, 'pushy_token': null, 'is_active': false})
          .eq('fcm_token', fcmToken)
          .neq('installation_id', installationId);
    }
    if (pushyToken != null && pushyToken.isNotEmpty) {
      await supabase
          .from('ansar_device_installations')
          .update({'fcm_token': null, 'pushy_token': null, 'is_active': false})
          .eq('pushy_token', pushyToken)
          .neq('installation_id', installationId);
    }
    try {
      await supabase.from('ansar_device_installations').upsert(values, onConflict: 'installation_id');
    } catch (error) {
      if (!error.toString().contains('notification_capabilities')) rethrow;
      final compatibleValues = Map<String, Object?>.from(values)..remove('notification_capabilities');
      await supabase.from('ansar_device_installations').upsert(compatibleValues, onConflict: 'installation_id');
    }
  } catch (_) {
    if (fcmToken == null || fcmToken.isEmpty) rethrow;
  }
  final previews = <String>[
    if (fcmToken != null && fcmToken.isNotEmpty) 'F:${tokenPreview(fcmToken)}',
    if (pushyToken != null && pushyToken.isNotEmpty) 'P:${tokenPreview(pushyToken)}',
  ];
  if (previews.isNotEmpty) lastNotificationTokenPreview = previews.join('  ');
  lastNotificationRegistrationError = null;
  lastNotificationRegistrationAt = DateTime.now();
}

String tokenPreview(String token) {
  return token.length <= 12 ? token : '${token.substring(0, 6)}...${token.substring(token.length - 6)}';
}

Future<void> saveLegacyFirebaseToken(EmployeeSession session, String token) async {
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

String compactDatabaseError(Object? error) {
  final text = error.toString().replaceFirst('Exception: ', '');
  final messageMatch = RegExp(r'message:\s*([^,]+),\s*code:', caseSensitive: false).firstMatch(text);
  final message = messageMatch?.group(1)?.trim();
  if (message != null && message.isNotEmpty) return message;
  if (text.contains('PGRST202') || text.contains('Could not find the function')) {
    return 'دالة قاعدة البيانات غير مثبتة أو لم يُحدّث مخطط Supabase بعد';
  }
  if (text.contains('column') && text.contains('does not exist')) {
    return 'أعمدة التحديث غير مثبتة في قاعدة البيانات';
  }
  if (text.contains('SocketException') || text.contains('TimeoutException') || text.contains('Failed host lookup')) {
    return 'تعذر الاتصال بقاعدة البيانات';
  }
  return text.length > 150 ? '${text.substring(0, 150)}...' : text;
}

String transferActionError(Object? error, {required String action}) {
  final message = compactDatabaseError(error);
  if (message.contains('ansar-runtime-repair.sql')) return message;
  if (message.isEmpty) return 'تعذر $action الآن. حاول مرة أخرى.';
  return 'تعذر $action: $message';
}

String chatUpgradeError(Object? error) {
  final text = error.toString();
  if (text.contains('reply_to_id') ||
      text.contains('edited_at') ||
      text.contains('edited_by') ||
      text.contains('deleted_by') ||
      text.contains('forwarded_from_id') ||
      text.contains('attachments') ||
      text.contains('transfer_order_id') ||
      text.contains('ansar_chat_message_receipts') ||
      text.contains('muted_until') ||
      text.contains('is_muted') ||
      text.contains('ansar_chat_message_hidden')) {
    return 'يلزم تنفيذ ملف تحديث الدردشة الجديد في Supabase أولاً.';
  }
  return cleanError(error);
}

String chatAttachmentError(Object? error) {
  final text = error.toString();
  if (text.contains('Bucket not found') || text.contains('ansar-chat')) {
    return 'مساحة مرفقات الدردشة غير مهيأة. نفّذ ملف ansar-realtime-rich-upgrade.sql في Supabase.';
  }
  if (text.contains('row-level security') || text.contains('Unauthorized') || text.contains('403')) {
    return 'رفضت قاعدة البيانات رفع المرفق. أعد تنفيذ سياسات مساحة ansar-chat.';
  }
  if (text.contains('SocketException') || text.contains('TimeoutException') || text.contains('Failed host lookup')) {
    return 'انقطع الاتصال أثناء رفع المرفق. بقي الملف جاهزاً لإعادة الإرسال.';
  }
  if (text.contains('Payload too large') || text.contains('413')) {
    return 'حجم المرفق أكبر من 10 ميغابايت.';
  }
  final cleaned = cleanError(error);
  return cleaned.isEmpty ? 'تعذر رفع المرفق. بقي جاهزاً لإعادة المحاولة.' : cleaned;
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

DateTime parseChatDate(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '')?.toLocal() ?? DateTime.now();
}

bool sameCalendarDay(DateTime first, DateTime second) {
  return first.year == second.year && first.month == second.month && first.day == second.day;
}

String chatDayLabel(DateTime value) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(value.year, value.month, value.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'اليوم';
  if (difference == 1) return 'أمس';
  return '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
}

String chatListTime(Object? value) {
  final date = parseChatDate(value);
  final now = DateTime.now();
  if (sameCalendarDay(date, now)) return formatTime(date);
  final yesterday = now.subtract(const Duration(days: 1));
  if (sameCalendarDay(date, yesterday)) return 'أمس';
  return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
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
  final number = value is num ? value.toDouble() : double.tryParse(value.toString());
  if (number == null) return '$value';
  return intl.NumberFormat('#,##0.##', 'en_US').format(number);
}

List<List<T>> chunkList<T>(List<T> values, int size) {
  if (values.isEmpty) return <List<T>>[];
  return [
    for (var index = 0; index < values.length; index += size)
      values.sublist(index, (index + size).clamp(0, values.length).toInt()),
  ];
}

String shortPdfText(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength - 1)}…';
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
  final discount = invoiceItemDiscountPercent(item);
  if (discount > 0) return '${formatMoneyValue(discount)}%';
  return '-';
}

double invoiceItemDiscountPercent(Map<String, dynamic> item) {
  final explicit = parseDiscountItem(item['remarki']);
  if (explicit > 0) return explicit;
  final quantity = doubleValue(item['quantity']);
  final price = doubleValue(item['price']);
  final value = doubleValue(item['value']);
  final gross = quantity * price;
  if (gross > 0 && value < gross - 0.001) {
    return (1 - value / gross) * 100;
  }
  return 0;
}

pw.Widget pdfTotalLine(
  String label,
  String value, {
  PdfColor color = PdfColors.black,
  bool bold = false,
}) {
  return pw.Row(
    children: [
      pw.Expanded(child: pw.Text(label, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700))),
      pw.Text(
        value,
        style: pw.TextStyle(
          color: color,
          fontSize: bold ? 13 : 10,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    ],
  );
}

Future<pw.MemoryImage?> loadPdfMemoryImage(String? assetPath) async {
  if (assetPath == null || assetPath.isEmpty) return null;
  try {
    final bytes = await rootBundle.load(assetPath);
    return pw.MemoryImage(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } catch (_) {
    return null;
  }
}

pw.Widget transferPdfBranchBadge(String name, pw.MemoryImage? logo) {
  return pw.Container(
    width: 180,
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: pw.BoxDecoration(
      color: const PdfColor.fromInt(0xfff4f8f7),
      border: pw.Border.all(color: PdfColors.grey300),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Row(
      children: [
        pw.Container(
          width: 38,
          height: 38,
          padding: const pw.EdgeInsets.all(3),
          decoration: pw.BoxDecoration(
            color: PdfColors.white,
            border: pw.Border.all(color: PdfColors.grey300),
            borderRadius: pw.BorderRadius.circular(5),
          ),
          child: logo == null
              ? pw.Center(
                  child: pw.Text(
                    name.isEmpty ? '-' : name.substring(0, 1),
                    style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
                  ),
                )
              : pw.Image(logo, fit: pw.BoxFit.contain),
        ),
        pw.SizedBox(width: 9),
        pw.Expanded(
          child: pw.Text(
            name,
            maxLines: 2,
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
        ),
      ],
    ),
  );
}

String arabicUsdAmountInWords(double amount) {
  final safeAmount = amount.isFinite ? amount.abs() : 0.0;
  final totalCents = (safeAmount * 100).round();
  final dollars = totalCents ~/ 100;
  final cents = totalCents % 100;
  final dollarText = dollars == 0
      ? 'صفر دولار أمريكي'
      : dollars == 1
          ? 'دولار أمريكي واحد'
          : dollars == 2
              ? 'دولاران أمريكيان'
              : '${arabicIntegerInWords(dollars)} دولاراً أمريكياً';
  final centText = cents == 0
      ? ''
      : cents == 1
          ? ' وسنت واحد'
          : cents == 2
              ? ' وسنتان'
              : ' و${arabicIntegerInWords(cents)} سنتاً';
  return 'فقط $dollarText$centText لا غير';
}

String arabicIntegerInWords(int value) {
  if (value == 0) return 'صفر';
  if (value < 0) return 'سالب ${arabicIntegerInWords(-value)}';
  final parts = <String>[];
  final billions = value ~/ 1000000000;
  final millions = (value ~/ 1000000) % 1000;
  final thousands = (value ~/ 1000) % 1000;
  final remainder = value % 1000;
  if (billions > 0) parts.add(arabicScaleWords(billions, 'مليار', 'ملياران', 'مليارات'));
  if (millions > 0) parts.add(arabicScaleWords(millions, 'مليون', 'مليونان', 'ملايين'));
  if (thousands > 0) parts.add(arabicScaleWords(thousands, 'ألف', 'ألفان', 'آلاف'));
  if (remainder > 0) parts.add(arabicBelowThousand(remainder));
  return parts.join(' و');
}

String arabicScaleWords(int value, String singular, String dual, String plural) {
  if (value == 1) return singular;
  if (value == 2) return dual;
  if (value >= 3 && value <= 10) return '${arabicBelowThousand(value)} $plural';
  return '${arabicBelowThousand(value)} $singular';
}

String arabicBelowThousand(int value) {
  const ones = [
    '',
    'واحد',
    'اثنان',
    'ثلاثة',
    'أربعة',
    'خمسة',
    'ستة',
    'سبعة',
    'ثمانية',
    'تسعة',
    'عشرة',
    'أحد عشر',
    'اثنا عشر',
    'ثلاثة عشر',
    'أربعة عشر',
    'خمسة عشر',
    'ستة عشر',
    'سبعة عشر',
    'ثمانية عشر',
    'تسعة عشر',
  ];
  const tens = ['', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
  const hundreds = ['', 'مائة', 'مائتان', 'ثلاثمائة', 'أربعمائة', 'خمسمائة', 'ستمائة', 'سبعمائة', 'ثمانمائة', 'تسعمائة'];
  final parts = <String>[];
  final hundred = value ~/ 100;
  final rest = value % 100;
  if (hundred > 0) parts.add(hundreds[hundred]);
  if (rest > 0) {
    if (rest < 20) {
      parts.add(ones[rest]);
    } else {
      final unit = rest % 10;
      final ten = rest ~/ 10;
      parts.add(unit == 0 ? tens[ten] : '${ones[unit]} و${tens[ten]}');
    }
  }
  return parts.join(' و');
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
    case 'receipt_confirmed':
      return note ?? 'تأكيد استلام المناقلة';
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
