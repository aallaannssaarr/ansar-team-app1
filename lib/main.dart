import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
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

final supabase = Supabase.instance.client;
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

const brandColor = Color(0xff087568);
const accentColor = Color(0xffc9952f);
const inkColor = Color(0xff20302c);
const softSurface = Color(0xfff5f7f6);
const panelSurface = Color(0xffffffff);

class AnsarApp extends StatelessWidget {
  const AnsarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'فريق الأنصار',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandColor,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: softSurface,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: softSurface,
          foregroundColor: inkColor,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: panelSurface,
          elevation: 0,
          margin: EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xffe3e8e6)),
          ),
        ),
      ),
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
  });

  final String id;
  final String name;
  final String username;
  final int branchNum;
  final String role;
  final bool isActive;

  factory EmployeeLite.fromRow(Map<String, dynamic> row) {
    return EmployeeLite(
      id: row['id'] as String,
      name: (row['display_name'] ?? row['full_name'] ?? row['username'] ?? '') as String,
      username: row['username'] as String? ?? '',
      branchNum: (row['branch_num'] as num?)?.toInt() ?? 0,
      role: row['role'] as String? ?? 'employee',
      isActive: row['is_active'] != false,
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

class ReportData {
  ReportData({
    required this.branches,
    required this.employees,
    required this.durations,
    required this.dailyHours,
    required this.totalHours,
    required this.openLogs,
    required this.closedLogs,
  });

  final Map<int, BranchOption> branches;
  final List<EmployeeLite> employees;
  final List<EmployeeDuration> durations;
  final Map<String, double> dailyHours;
  final double totalHours;
  final int openLogs;
  final int closedLogs;

  double get averageHours => closedLogs == 0 ? 0 : totalHours / closedLogs;
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
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset('assets/logo.png', height: 128, fit: BoxFit.contain),
                  const SizedBox(height: 18),
                  const Text(
                    'فريق الأنصار',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'إدارة الدوام والمناقلات والتقارير الداخلية',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 34),
                  TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستخدم',
                      prefixIcon: Icon(Icons.person_rounded),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => login(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: loading ? null : login,
                    icon: loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_rounded),
                    label: const Text('دخول'),
                  ),
                ],
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
      final title = message.notification?.title ?? 'إشعار جديد';
      final body = message.notification?.body ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(body.isEmpty ? title : '$title\n$body')),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(body.isEmpty ? title : '$title\n$body')),
        );
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

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(session: session),
      ReportsPage(session: session),
      TransfersPage(session: session),
      QueriesPage(session: session),
      ChatPage(session: session),
      ProfilePage(session: session, onSessionChanged: updateSession),
      if (session.canManageEmployees) ManagementPage(session: session),
    ];

    final destinations = [
      const NavigationDestination(icon: Icon(Icons.home_rounded), label: 'الرئيسية'),
      const NavigationDestination(icon: Icon(Icons.query_stats_rounded), label: 'التقارير'),
      const NavigationDestination(icon: Icon(Icons.sync_alt_rounded), label: 'المناقلات'),
      const NavigationDestination(icon: Icon(Icons.search_rounded), label: 'استعلام'),
      const NavigationDestination(icon: Icon(Icons.chat_rounded), label: 'الدردشة'),
      const NavigationDestination(icon: Icon(Icons.person_rounded), label: 'حسابي'),
      if (session.canManageEmployees)
        const NavigationDestination(icon: Icon(Icons.admin_panel_settings_rounded), label: 'إدارة'),
    ];

    if (index >= pages.length) index = 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(session.name),
        actions: [
          IconButton(
            tooltip: 'خروج',
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => const Directionality(
                  textDirection: TextDirection.rtl,
                  child: LoginPage(),
                ),
              ),
            ),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: destinations,
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
  Timer? timer;
  bool attendanceBusy = false;
  bool movementsExpanded = false;

  @override
  void initState() {
    super.initState();
    future = loadDashboard();
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => future = loadDashboard());
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<DashboardData> loadDashboard() async {
    final branches = await loadAppBranchesMap();
    final employeeRows = await supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, username, branch_num, role, is_active')
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
      if (mounted) setState(() => future = loadDashboard());
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
      if (mounted) setState(() => future = loadDashboard());
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => attendanceBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () {
        final refreshed = loadDashboard();
        setState(() => future = refreshed);
        return refreshed.then((_) {});
      },
      child: FutureBuilder<DashboardData>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(
              message: cleanError(snapshot.error),
              onRetry: () => setState(() => future = loadDashboard()),
            );
          }

          final data = snapshot.data!;
          final isWorking = data.openLog != null;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: isWorking ? Colors.green.shade50 : Colors.grey.shade100,
                            child: Icon(
                              isWorking ? Icons.work_history_rounded : Icons.work_off_rounded,
                              color: isWorking ? Colors.green : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isWorking ? 'أنت داخل العمل الآن' : 'لا يوجد دوام مفتوح',
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                Text(data.branchName, style: const TextStyle(color: Colors.black54)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: isWorking || attendanceBusy ? null : checkIn,
                              icon: attendanceBusy && !isWorking
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.login_rounded),
                              label: Text(attendanceBusy && !isWorking ? 'جاري الدخول' : 'دخول'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: isWorking && !attendanceBusy ? () => checkOut(data.openLog!) : null,
                              icon: attendanceBusy && isWorking
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.logout_rounded),
                              label: Text(attendanceBusy && isWorking ? 'جاري الخروج' : 'خروج'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      title: 'داخل العمل الآن',
                      value: '${data.activeNow}',
                      icon: Icons.work_history_rounded,
                      color: brandColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      title: 'سجلوا اليوم',
                      value: '${data.checkedInToday}',
                      icon: Icons.today_rounded,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const SectionHeader(title: 'حالة الفروع الآن'),
              if (data.branchStatuses.isEmpty)
                const EmptyState(icon: Icons.storefront_rounded, text: 'لا توجد فروع مسجلة')
              else
                ...data.branchStatuses.map((branch) => BranchStatusCard(branch: branch)),
              const SizedBox(height: 16),
              Card(
                child: ExpansionTile(
                  initiallyExpanded: movementsExpanded,
                  onExpansionChanged: (value) => setState(() => movementsExpanded = value),
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('آخر الحركات', style: TextStyle(fontWeight: FontWeight.bold)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'تحديث',
                        onPressed: () => setState(() => future = loadDashboard()),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      Icon(movementsExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                    ],
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: [
                    if (data.movements.isEmpty)
                      const EmptyState(
                        icon: Icons.event_busy_rounded,
                        text: 'لا توجد حركات دوام بعد',
                      )
                    else
                      ...data.movements.map((movement) => MovementTile(movement: movement)),
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

  @override
  void initState() {
    super.initState();
    selectedBranch = widget.session.isAdmin ? null : widget.session.branchNum;
    selectedEmployeeId = widget.session.isAdmin || widget.session.isBranchManager ? null : widget.session.id;
    future = loadReports();
  }

  Future<ReportData> loadReports() async {
    final branches = await loadAppBranchesMap();
    var employees = await loadEmployeesForScope(widget.session, includeInactive: false);
    if (selectedBranch != null) {
      employees = employees.where((employee) => employee.branchNum == selectedBranch).toList();
    }
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

      final dayKey = shortDate(checkIn);
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
      durations: durations,
      dailyHours: dailyHours,
      totalHours: totalHours,
      openLogs: openLogs,
      closedLogs: closedLogs,
    );
  }

  void reload() {
    setState(() => future = loadReports());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReportData>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(message: cleanError(snapshot.error), onRetry: reload);
        }
        final data = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: days,
                            decoration: const InputDecoration(labelText: 'الفترة'),
                            items: const [
                              DropdownMenuItem(value: 7, child: Text('آخر 7 أيام')),
                              DropdownMenuItem(value: 30, child: Text('آخر 30 يوم')),
                              DropdownMenuItem(value: 90, child: Text('آخر 90 يوم')),
                            ],
                            onChanged: (value) {
                              days = value ?? 30;
                              reload();
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          tooltip: 'تحديث',
                          onPressed: reload,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                    if (widget.session.isAdmin) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int?>(
                        initialValue: selectedBranch,
                        decoration: const InputDecoration(labelText: 'الفرع'),
                        items: [
                          const DropdownMenuItem<int?>(value: null, child: Text('كل الفروع')),
                          ...data.branches.values.map(
                            (branch) => DropdownMenuItem<int?>(
                              value: branch.number,
                              child: Text(branch.label),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          selectedBranch = value;
                          selectedEmployeeId = null;
                          reload();
                        },
                      ),
                    ],
                    if (widget.session.isAdmin || widget.session.isBranchManager) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String?>(
                        initialValue: selectedEmployeeId,
                        decoration: const InputDecoration(labelText: 'الموظف'),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('كل الموظفين')),
                          ...data.employees.map(
                            (employee) => DropdownMenuItem<String?>(
                              value: employee.id,
                              child: Text(employee.name),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          selectedEmployeeId = value;
                          reload();
                        },
                      ),
                    ],
                  ],
                ),
              ),
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
                    color: const Color(0xff5b6f95),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    title: 'دوام مفتوح',
                    value: '${data.openLogs}',
                    icon: Icons.pending_actions_rounded,
                    color: const Color(0xffa14d3a),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'الساعات حسب الأيام'),
            if (data.dailyHours.isEmpty)
              const EmptyState(icon: Icons.bar_chart_rounded, text: 'لا توجد بيانات للفترة المحددة')
            else
              SizedBox(height: 230, child: DailyHoursChart(values: data.dailyHours)),
            const SizedBox(height: 16),
            const SectionHeader(title: 'ترتيب الموظفين'),
            if (data.durations.isEmpty)
              const EmptyState(icon: Icons.people_outline_rounded, text: 'لا توجد سجلات مطابقة')
            else
              ...data.durations.map((item) => DurationListTile(item: item)),
          ],
        );
      },
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
      padding: const EdgeInsets.all(16),
      children: [
        _QueryModeTabs(
          selected: queryMode,
          onChanged: (value) {
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
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        labelText: 'اكتب كلمة البحث',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onSubmitted: (_) => submitSearch(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: submitSearch,
                    child: const Text('بحث'),
                  ),
                ],
              ),
            ),
          ),
        if (queryMode == 1 || queryMode == 3) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: startDate,
                  decoration: const InputDecoration(labelText: 'من تاريخ'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: endDate,
                  decoration: const InputDecoration(labelText: 'إلى تاريخ'),
                ),
              ),
            ],
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
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = items[index];
          final active = selected == item.value;
          return ChoiceChip(
            selected: active,
            selectedColor: brandColor,
            avatar: Icon(item.icon, size: 18, color: active ? Colors.white : brandColor),
            label: Text(item.label, maxLines: 1, overflow: TextOverflow.visible),
            labelStyle: TextStyle(
              color: active ? Colors.white : inkColor,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
            onSelected: (_) => onChanged(item.value),
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
            onPressed: () => setState(() => future = loadEntries()),
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
              if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: () => setState(() => future = loadEntries()));
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
          if (snapshot.hasError) return ErrorState(message: cleanError(snapshot.error), onRetry: () => setState(() => future = loadItems()));
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
                            backgroundColor: brandColor.withOpacity(0.1),
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
                ...items.map((item) {
                  final itemSto = parseStoNum(item['remarki']);
                  final itemDiscount = discountDisplay(item);
                  return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                InfoChip(icon: Icons.numbers_rounded, label: 'كمية ${formatMoneyValue(item['quantity'])}'),
                                InfoChip(icon: Icons.sell_rounded, label: 'سعر ${formatMoneyValue(item['price'])}'),
                                InfoChip(icon: Icons.percent_rounded, label: 'حسم $itemDiscount'),
                                InfoChip(icon: Icons.calculate_rounded, label: 'قيمة ${formatMoneyValue(item['value'])}'),
                                InfoChip(
                                  icon: Icons.warehouse_rounded,
                                  label: itemSto == null ? 'مستودع غير محدد' : branchLabel(data.branches, itemSto),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                }),
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
    return Card(
      child: ExpansionTile(
        leading: const CircleAvatar(child: Icon(Icons.menu_book_rounded)),
        title: Text(product['name'] as String? ?? 'بدون اسم'),
        subtitle: Text('رقم المادة $matNum · إجمالي الكمية ${formatMoneyValue(product['quantity'])}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PriceChip(label: 'سعر الجرد', value: product['jard_price']),
              PriceChip(label: 'السعر القائم', value: product['regular_price']),
              PriceChip(label: 'سعر المكتبات', value: product['price1']),
              PriceChip(label: 'سعر المعاهد', value: product['price2']),
              PriceChip(label: 'سعر المفرق', value: product['price3']),
            ],
          ),
          const SizedBox(height: 10),
          if (result.stock.isEmpty)
            const Align(
              alignment: Alignment.centerRight,
              child: Text('لا توجد كميات حسب الفروع', style: TextStyle(color: Colors.black54)),
            )
          else
            ...result.stock.take(10).map(
                  (stock) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      stock.quantity > 0 ? Icons.storefront_rounded : Icons.storefront_outlined,
                      color: stock.quantity > 0 ? brandColor : Colors.black38,
                    ),
                    title: Text(stock.branchName),
                    trailing: Text(formatMoneyValue(stock.quantity)),
                  ),
                ),
        ],
      ),
    );
  }
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SegmentedButton<int>(
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
      if (mounted) setState(() => employeesFuture = loadEmployees());
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
      if (mounted) setState(() => employeesFuture = loadEmployees());
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
            onRetry: () => setState(() => employeesFuture = loadEmployees()),
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
      if (mounted) setState(() => future = loadAppBranchesMap());
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
      if (mounted) setState(() => future = loadAppBranchesMap());
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
            onRetry: () => setState(() => future = loadAppBranchesMap()),
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
            onRetry: () => setState(() => future = loadDiagnostics()),
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
          .select()
          .limit(1);
      if (rows.isNotEmpty) widget.onSessionChanged(EmployeeSession(rows.first));
      setState(() => message = 'تم حفظ بياناتك');
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
      setState(() => message = 'تعذر رفع الصورة. نفذ ملف docs/ansar-storage-policies.sql ثم حاول مجددا. ${cleanError(e)}');
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
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                EmployeeAvatar(name: widget.session.name, imageUrl: widget.session.avatarUrl, radius: 42),
                const SizedBox(height: 10),
                Text(widget.session.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text(roleLabel(widget.session.role), style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: saving ? null : pickAvatar,
                  icon: const Icon(Icons.photo_camera_rounded),
                  label: const Text('تغيير الصورة'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: registeringNotifications ? null : enableNotifications,
                  icon: registeringNotifications
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.notifications_active_rounded),
                  label: const Text('تفعيل الإشعارات'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: registeringNotifications ? null : resetNotifications,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة ضبط الإشعارات'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
        TextField(controller: username, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
        TextField(controller: jobTitle, decoration: const InputDecoration(labelText: 'المسمى الوظيفي')),
        TextField(controller: phone, decoration: const InputDecoration(labelText: 'الهاتف')),
        TextField(controller: email, decoration: const InputDecoration(labelText: 'البريد')),
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(message!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: saving ? null : () => saveProfile(),
          icon: saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_rounded),
          label: const Text('حفظ'),
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
  String statusFilter = 'active';
  int? fromBranchFilter;
  int? toBranchFilter;
  bool transferBusy = false;

  @override
  void initState() {
    super.initState();
    future = loadTransfers();
    unawaited(warmProductSearchCache());
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
      final fromBranch = (row['from_branch_num'] as num?)?.toInt();
      final toBranch = (row['to_branch_num'] as num?)?.toInt();
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
      final fromBranch = (order['from_branch_num'] as num?)?.toInt();
      final toBranch = (order['to_branch_num'] as num?)?.toInt();
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
    final result = await showDialog<CreateTransferResult>(
      context: context,
      builder: (_) => TransferDialog(
        session: widget.session,
        branches: data.branches,
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
        data: {'type': 'transfer_created', 'order_id': inserted['id']},
      ));
      if (mounted) setState(() => future = loadTransfers());
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => transferBusy = false);
    }
  }

  Future<void> updateOrderStatus(Map<String, dynamic> order) async {
    final toBranch = (order['to_branch_num'] as num?)?.toInt();
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
        data: {'type': 'transfer_updated', 'order_id': order['id'], 'status': status},
      ));
      if (mounted) setState(() => future = loadTransfers());
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
    if (mounted) setState(() => future = loadTransfers());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TransferData>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorState(
            message: cleanError(snapshot.error),
            onRetry: () => setState(() => future = loadTransfers()),
          );
        }
        final data = snapshot.data!;
        final visibleOrders = filteredOrders(data.orders);
        return Scaffold(
          body: Column(
            children: [
              _TransferFilters(
                branches: data.branches,
                orders: data.orders,
                statusFilter: statusFilter,
                fromBranchFilter: fromBranchFilter,
                toBranchFilter: toBranchFilter,
                onStatusChanged: (value) => setState(() => statusFilter = value),
                onFromChanged: (value) => setState(() => fromBranchFilter = value),
                onToChanged: (value) => setState(() => toBranchFilter = value),
                onRefresh: () => setState(() => future = loadTransfers()),
              ),
              Expanded(
                child: visibleOrders.isEmpty
                    ? EmptyState(
                        icon: Icons.sync_alt_rounded,
                        text: 'لا توجد مناقلات ضمن هذا العرض',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleOrders.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final order = visibleOrders[i];
                    final fromBranch = (order['from_branch_num'] as num?)?.toInt() ?? 0;
                    final toBranch = (order['to_branch_num'] as num?)?.toInt() ?? 0;
                    final requester = data.employees[order['requested_by']];
                    final canHandle = widget.session.isAdmin || toBranch == widget.session.branchNum;
                    final status = order['status'] as String? ?? 'submitted';
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: transferStatusColor(status).withOpacity(0.12),
                          child: Icon(transferStatusIcon(status), color: transferStatusColor(status)),
                        ),
                        title: Text('طلب رقم ${order['order_no'] ?? '-'}'),
                        subtitle: Text(
                          '${branchLabel(data.branches, fromBranch)} ← ${branchLabel(data.branches, toBranch)}\n'
                          '${requester?.name ?? 'موظف'} · ${statusLabel(status)}',
                        ),
                        isThreeLine: true,
                        onTap: () => openOrderDetails(order, data),
                        trailing: canHandle
                            ? IconButton(
                                tooltip: 'تحديث الحالة',
                                onPressed: transferBusy ? null : () => updateOrderStatus(order),
                                icon: transferBusy
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.edit_note_rounded),
                              )
                            : const Icon(Icons.chevron_left_rounded),
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
    required this.onRefresh,
  });

  final Map<int, BranchOption> branches;
  final List<Map<String, dynamic>> orders;
  final String statusFilter;
  final int? fromBranchFilter;
  final int? toBranchFilter;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<int?> onFromChanged;
  final ValueChanged<int?> onToChanged;
  final VoidCallback onRefresh;

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
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int?>(
                  initialValue: fromBranchFilter,
                  decoration: const InputDecoration(
                    labelText: 'من فرع',
                    prefixIcon: Icon(Icons.call_made_rounded),
                  ),
                  items: branchItems,
                  onChanged: onFromChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<int?>(
                  initialValue: toBranchFilter,
                  decoration: const InputDecoration(
                    labelText: 'إلى فرع',
                    prefixIcon: Icon(Icons.call_received_rounded),
                  ),
                  items: branchItems,
                  onChanged: onToChanged,
                ),
              ),
              IconButton(
                tooltip: 'تحديث',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
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
  bool sharingPdf = false;

  bool get canHandle {
    final toBranch = (widget.order['to_branch_num'] as num?)?.toInt();
    return widget.session.isAdmin || toBranch == widget.session.branchNum;
  }

  @override
  void initState() {
    super.initState();
    future = loadItems();
  }

  Future<TransferDetailsData> loadItems() async {
    final items = await supabase
        .from('ansar_transfer_order_items')
        .select()
        .eq('order_id', widget.order['id'])
        .order('created_at', ascending: true);
    final result = items.cast<Map<String, dynamic>>();
    final matNums = result
        .map((row) => (row['mat_num'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    final products = matNums.isEmpty
        ? <Map<String, dynamic>>[]
        : await supabase
            .from('products')
            .select('mat_num, name, quantity')
            .inFilter('mat_num', matNums);
    final productByMat = {
      for (final row in products.cast<Map<String, dynamic>>())
        (row['mat_num'] as num).toInt(): row,
    };
    final enrichedItems = result
        .map((row) => {
              ...row,
              'product': productByMat[(row['mat_num'] as num?)?.toInt()],
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
        .select('id, display_name, full_name, username, branch_num, role, is_active');
    final employees = {
      for (final row in employeesRows.cast<Map<String, dynamic>>())
        row['id'] as String: EmployeeLite.fromRow(row),
    };
    return TransferDetailsData(items: enrichedItems, events: events, employees: employees);
  }

  Future<void> updateItem(Map<String, dynamic> item, String status) async {
    if (!canHandle) return;
    final requested = (item['requested_quantity'] as num?)?.toDouble() ?? 0;
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
      approved = value;
    }
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
      data: {'type': 'transfer_item_updated', 'order_id': widget.order['id']},
    ));
    setState(() => future = loadItems());
  }

  Future<void> changeStatus() async {
    if (!canHandle) return;
    final status = await showDialog<String>(
      context: context,
      builder: (_) => StatusDialog(current: widget.order['status'] as String? ?? 'submitted'),
    );
    if (status == null) return;
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
      'old_status': widget.order['status'],
      'new_status': status,
    });
    unawaited(enqueueNotification(
      title: 'تحديث مناقلة',
      body: 'تم تحديث حالة المناقلة رقم ${widget.order['order_no'] ?? '-'} إلى ${statusLabel(status)}',
      data: {'type': 'transfer_updated', 'order_id': widget.order['id'], 'status': status},
    ));
    if (mounted) Navigator.pop(context);
  }

  Future<void> sharePdf(TransferDetailsData data) async {
    setState(() => sharingPdf = true);
    try {
      final bytes = await buildTransferPdf(data);
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'transfer-${widget.order['order_no'] ?? widget.order['id']}.pdf',
      );
    } catch (error) {
      if (mounted) showSnack(context, cleanError(error));
    } finally {
      if (mounted) setState(() => sharingPdf = false);
    }
  }

  Future<Uint8List> buildTransferPdf(TransferDetailsData data) async {
    final fromBranch = (widget.order['from_branch_num'] as num?)?.toInt() ?? 0;
    final toBranch = (widget.order['to_branch_num'] as num?)?.toInt() ?? 0;
    final font = await PdfGoogleFonts.cairoRegular();
    final bold = await PdfGoogleFonts.cairoBold();
    final theme = pw.ThemeData.withFont(base: font, bold: bold);
    final document = pw.Document(theme: theme);
    final headers = ['الكتاب', 'المطلوب', 'المتوفر', 'الحالة', 'ملاحظة'];
    final rows = data.items.map((item) {
      final product = item['product'] as Map<String, dynamic>?;
      final requested = item['requested_quantity']?.toString() ?? '-';
      final approved = item['approved_quantity']?.toString() ?? '-';
      final status = itemStatusLabel(item['item_status'] as String? ?? 'requested');
      return [
        product?['name'] as String? ?? 'مادة ${item['mat_num']}',
        requested,
        approved,
        status,
        item['note']?.toString() ?? '',
      ];
    }).toList();
    document.addPage(
      pw.MultiPage(
        textDirection: pw.TextDirection.rtl,
        pageTheme: const pw.PageTheme(
          margin: pw.EdgeInsets.all(28),
        ),
        build: (context) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('فريق الأنصار', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
              pw.Text('تقرير مناقلة', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('رقم الطلب: ${widget.order['order_no'] ?? '-'}'),
                pw.Text('من: ${branchLabel(widget.branches, fromBranch)}'),
                pw.Text('إلى: ${branchLabel(widget.branches, toBranch)}'),
                pw.Text('الحالة: ${statusLabel(widget.order['status'] as String? ?? 'submitted')}'),
                pw.Text('تاريخ التقرير: ${formatDateTime(DateTime.now())}'),
              ],
            ),
          ),
          pw.SizedBox(height: 18),
          pw.Text('بنود المناقلة', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: rows,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: pw.BoxDecoration(color: PdfColor.fromInt(0xff087568)),
            cellAlignment: pw.Alignment.centerRight,
            headerAlignment: pw.Alignment.centerRight,
            border: pw.TableBorder.all(color: PdfColors.grey300),
          ),
          if (data.events.isNotEmpty) ...[
            pw.SizedBox(height: 18),
            pw.Text('سجل المعالجة', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            ...data.events.take(8).map((event) {
              final employee = data.employees[event['employee_id']];
              return pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 5),
                child: pw.Text(
                  '${eventLabel(event)} - ${employee?.name ?? 'موظف'} - ${formatEventTime(event['created_at'])}',
                ),
              );
            }),
          ],
        ],
      ),
    );
    return document.save();
  }

  @override
  Widget build(BuildContext context) {
    final fromBranch = (widget.order['from_branch_num'] as num?)?.toInt() ?? 0;
    final toBranch = (widget.order['to_branch_num'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text('مناقلة ${widget.order['order_no'] ?? ''}'),
        actions: [
          if (canHandle)
            IconButton(
              tooltip: 'تغيير الحالة',
              onPressed: changeStatus,
              icon: const Icon(Icons.edit_note_rounded),
            ),
        ],
      ),
      body: FutureBuilder<TransferDetailsData>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorState(message: cleanError(snapshot.error), onRetry: () => setState(() => future = loadItems()));
          }
          final details = snapshot.data!;
          final items = details.items;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  title: Text('${branchLabel(widget.branches, fromBranch)} ← ${branchLabel(widget.branches, toBranch)}'),
                  subtitle: Text(statusLabel(widget.order['status'] as String? ?? 'submitted')),
                  trailing: OutlinedButton.icon(
                    onPressed: sharingPdf ? null : () => sharePdf(details),
                    icon: sharingPdf
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_rounded),
                    label: const Text('PDF'),
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
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            product?['name'] as String? ?? 'مادة ${item['mat_num']}',
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
                      backgroundColor: brandColor.withOpacity(0.1),
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
    final options = widget.branches.keys.where((number) => number != widget.session.branchNum);
    if (options.isNotEmpty) toBranch = options.first;
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
    final parsedMat = (product?['mat_num'] as num?)?.toInt();
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
    return AlertDialog(
      title: const Text('طلب مناقلة'),
      content: SizedBox(
        width: 680,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.76),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: toBranch,
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
                TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة الطلب')),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: softSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: bookSearch,
                        decoration: InputDecoration(
                          labelText: 'ابحث عن الكتاب من قاعدة البيانات',
                          helperText: cacheLoading
                              ? 'يتم تجهيز فهرس الكتب لأول مرة'
                              : productsCount > 0
                                  ? 'جاهز للبحث السريع داخل $productsCount كتاب'
                                  : null,
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
                      if (suggestions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Card(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: suggestions
                                  .map(
                                    (product) => ListTile(
                                      dense: true,
                                      leading: const Icon(Icons.menu_book_rounded),
                                      title: Text(product['name'] as String? ?? 'بدون اسم'),
                                      subtitle: Text('رقم ${product['mat_num']} · كمية ${product['quantity'] ?? '-'}'),
                                      onTap: () => selectProduct(product),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: quantity,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: 'الكمية'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: itemNote,
                              decoration: const InputDecoration(labelText: 'ملاحظة البند'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: addItem,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('إضافة بند'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  const EmptyState(icon: Icons.playlist_add_rounded, text: 'أضف كتابا واحدا على الأقل')
                else
                  ...items.map((item) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.check_circle_outline_rounded, color: brandColor),
                        title: Text(item.name),
                        subtitle: Text('رقم ${item.matNum}${item.note.isEmpty ? '' : ' · ${item.note}'}'),
                        trailing: Text('${item.quantity}'),
                      )),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(
          onPressed: toBranch == null || items.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    CreateTransferResult(toBranch: toBranch!, note: note.text.trim(), items: items),
                  ),
          child: const Text('إرسال'),
        ),
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
    if (mounted) setState(() => future = loadThreads());
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
      if (mounted) setState(() => future = loadThreads());
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
            onRetry: () => setState(() => future = loadThreads()),
          );
        }
        final threads = snapshot.data!;
        return Scaffold(
          body: threads.isEmpty
              ? const EmptyState(icon: Icons.chat_bubble_outline_rounded, text: 'لا توجد محادثات بعد')
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: threads.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final thread = threads[i];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          child: Icon(thread['thread_type'] == 'general'
                              ? Icons.campaign_rounded
                              : Icons.forum_rounded),
                        ),
                        title: Text(thread['title'] as String? ?? 'محادثة'),
                        subtitle: Text(chatTypeLabel(thread['thread_type'] as String? ?? 'general')),
                        onTap: () => openThread(thread),
                      ),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: threadBusy ? null : createThread,
            icon: threadBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_comment_rounded),
            label: Text(threadBusy ? 'جاري الحفظ' : 'محادثة'),
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
  Timer? timer;
  RealtimeChannel? channel;
  bool sendingMessage = false;

  @override
  void initState() {
    super.initState();
    future = loadMessages();
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
          if (mounted) setState(() => future = loadMessages());
        },
      ).subscribe();
    timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) setState(() => future = loadMessages());
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    if (channel != null) supabase.removeChannel(channel!);
    message.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> loadMessages() async {
    final rows = await supabase
        .from('ansar_chat_messages')
        .select()
        .eq('thread_id', widget.thread['id'])
        .isFilter('deleted_at', null)
        .order('created_at', ascending: true)
        .limit(120);
    return rows.cast<Map<String, dynamic>>();
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
      if (mounted) setState(() => future = loadMessages());
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
    setState(() => future = loadMessages());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.thread['title'] as String? ?? 'محادثة'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: () => setState(() => future = loadMessages()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return ErrorState(
                    message: cleanError(snapshot.error),
                    onRetry: () => setState(() => future = loadMessages()),
                  );
                }
                final messages = snapshot.data!;
                if (messages.isEmpty) {
                  return const EmptyState(icon: Icons.mark_chat_unread_rounded, text: 'ابدأ أول رسالة');
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final row = messages[i];
                    final mine = row['sender_id'] == widget.session.id;
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Card(
                          color: mine ? brandColor.withValues(alpha: 0.1) : panelSurface,
                          child: InkWell(
                            onLongPress: () => deleteMessage(row),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(row['body'] as String? ?? ''),
                                  const SizedBox(height: 5),
                                  Text(
                                    formatDateTime(DateTime.parse(row['created_at'] as String).toLocal()),
                                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                                  ),
                                ],
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: message,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'اكتب رسالة',
                        border: OutlineInputBorder(),
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
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.14),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 4),
                  Text(value, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                ],
              ),
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
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isIn ? Colors.green.shade50 : Colors.red.shade50,
          child: Icon(
            isIn ? Icons.login_rounded : Icons.logout_rounded,
            color: isIn ? Colors.green : Colors.red,
          ),
        ),
        title: Text('${movement.employee.name} - ${movement.type}'),
        subtitle: Text('${movement.branchName} · ${formatDateTime(movement.time)}'),
      ),
    );
  }
}

class BranchStatusCard extends StatelessWidget {
  const BranchStatusCard({super.key, required this.branch});

  final BranchStatus branch;

  @override
  Widget build(BuildContext context) {
    final open = branch.isOpen;
    final count = branch.activeEmployees.length;
    final names = branch.activeEmployees.take(3).map((employee) => employee.name).join('، ');
    final extra = count > 3 ? ' و${count - 3} آخرين' : '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: open ? brandColor.withOpacity(0.12) : Colors.grey.shade100,
              child: Icon(
                open ? Icons.storefront_rounded : Icons.storefront_outlined,
                color: open ? brandColor : Colors.grey,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(branch.branchName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    open
                        ? 'مفتوح الآن · ${count == 1 ? 'موظف واحد' : '$count موظفين'}'
                        : 'مغلق الآن · لا يوجد موظفون داخل الفرع',
                    style: TextStyle(color: open ? brandColor : Colors.black54),
                  ),
                  if (open && names.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('$names$extra', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                ],
              ),
            ),
            Chip(
              avatar: Icon(open ? Icons.lock_open_rounded : Icons.lock_rounded, size: 16),
              label: Text(open ? 'مفتوح' : 'مغلق'),
              backgroundColor: open ? const Color(0xffe3f3ee) : Colors.grey.shade100,
            ),
          ],
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 20, 10, 8),
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxHours <= 0 ? 1 : maxHours * 1.2,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 34,
                  getTitlesWidget: (value, meta) {
                    final index = value.toInt();
                    if (index < 0 || index >= shown.length) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(shown[index].key, style: const TextStyle(fontSize: 10)),
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
                      color: i == shown.length - 1 ? accentColor : brandColor,
                      width: 14,
                      borderRadius: BorderRadius.circular(4),
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

class DurationListTile extends StatelessWidget {
  const DurationListTile({super.key, required this.item});

  final EmployeeDuration item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: EmployeeAvatar(name: item.employee.name),
      title: Text(item.employee.name),
      subtitle: Text('${item.days} أيام حضور · ${item.openLogs} مفتوح'),
      trailing: Text('${item.hours.toStringAsFixed(1)} ساعة'),
    );
  }
}

class EmployeeAvatar extends StatelessWidget {
  const EmployeeAvatar({super.key, required this.name, this.imageUrl, this.radius = 20});

  final String name;
  final String? imageUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final trimmedName = name.trim();
    final initials = trimmedName.isEmpty ? '؟' : trimmedName.substring(0, 1);
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(imageUrl!));
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: brandColor.withValues(alpha: 0.12),
      child: Text(initials, style: const TextStyle(color: brandColor, fontWeight: FontWeight.bold)),
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
            Icon(icon, size: 48, color: Colors.black38),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
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
            const Icon(Icons.error_outline_rounded, size: 54, color: Colors.red),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
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
      .select('id, display_name, full_name, username, branch_num, role, is_active');
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
  return error.toString().replaceFirst('Exception: ', '');
}

String formatTime(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String formatDateTime(DateTime value) {
  return '${shortDate(value)} ${formatTime(value)}';
}

String formatMoneyValue(Object? value) {
  if (value == null) return '-';
  final number = (value as num?)?.toDouble() ?? double.tryParse('$value');
  if (number == null) return '$value';
  if ((number - number.roundToDouble()).abs() < 0.001) return number.toStringAsFixed(0);
  return number.toStringAsFixed(2);
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
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
