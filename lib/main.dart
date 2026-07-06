import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ansar_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AnsarConfig.supabaseUrl,
    publishableKey: AnsarConfig.supabaseAnonKey,
  );
  runApp(const AnsarApp());
}

final supabase = Supabase.instance.client;

const brandColor = Color(0xff087568);
const accentColor = Color(0xffc9952f);
const surfaceTint = Color(0xfff5f7f6);

class AnsarApp extends StatelessWidget {
  const AnsarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'فريق الأنصار',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: brandColor),
        useMaterial3: true,
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: surfaceTint,
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
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
  String get name => (data['display_name'] ?? data['full_name'] ?? '') as String;
  String get username => data['username'] as String;
  int get branchNum => (data['branch_num'] as num).toInt();
  String get role => data['role'] as String? ?? 'employee';
  bool get canManageEmployees => data['can_manage_employees'] == true;
  bool get canManageAllBranches => data['can_manage_all_branches'] == true;
}

class BranchOption {
  BranchOption({required this.number, required this.name});

  final int number;
  final String name;

  String get label => '$name - فرع $number';
}

class EmployeeLite {
  EmployeeLite({
    required this.id,
    required this.name,
    required this.username,
    required this.branchNum,
  });

  final String id;
  final String name;
  final String username;
  final int branchNum;

  factory EmployeeLite.fromRow(Map<String, dynamic> row) {
    return EmployeeLite(
      id: row['id'] as String,
      name: (row['display_name'] ?? row['full_name'] ?? row['username'] ?? '') as String,
      username: row['username'] as String? ?? '',
      branchNum: (row['branch_num'] as num?)?.toInt() ?? 0,
    );
  }
}

class TodayAttendance {
  TodayAttendance({
    required this.employee,
    required this.branchName,
    required this.checkIn,
    required this.checkOut,
    required this.isOpen,
  });

  final EmployeeLite employee;
  final String branchName;
  final DateTime checkIn;
  final DateTime? checkOut;
  final bool isOpen;
}

class EmployeeDuration {
  EmployeeDuration({
    required this.employee,
    required this.hours,
    required this.days,
  });

  final EmployeeLite employee;
  final double hours;
  final int days;
}

class DashboardData {
  DashboardData({
    required this.branches,
    required this.todayLogs,
    required this.topDurations,
  });

  final Map<int, BranchOption> branches;
  final List<TodayAttendance> todayLogs;
  final List<EmployeeDuration> topDurations;

  int get activeNow => todayLogs.where((log) => log.isOpen).length;
  int get checkedInToday => todayLogs.length;
  double get totalHours30Days =>
      topDurations.fold(0.0, (sum, item) => sum + item.hours);
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
            child: HomePage(session: EmployeeSession(rows.first)),
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
      backgroundColor: surfaceTint,
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
                  Image.asset('assets/logo.png', height: 132, fit: BoxFit.contain),
                  const SizedBox(height: 18),
                  const Text(
                    'فريق الأنصار',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'إدارة الدوام والمناقلات والتواصل الداخلي',
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
  const HomePage({super.key, required this.session});

  final EmployeeSession session;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(session: widget.session),
      AttendancePage(session: widget.session),
      TransfersPage(session: widget.session),
      ChatPage(session: widget.session),
      if (widget.session.canManageEmployees) EmployeesPage(session: widget.session),
    ];

    final destinations = [
      const NavigationDestination(icon: Icon(Icons.home_rounded), label: 'الرئيسية'),
      const NavigationDestination(icon: Icon(Icons.schedule_rounded), label: 'الدوام'),
      const NavigationDestination(icon: Icon(Icons.sync_alt_rounded), label: 'المناقلات'),
      const NavigationDestination(icon: Icon(Icons.chat_rounded), label: 'الدردشة'),
      if (widget.session.canManageEmployees)
        const NavigationDestination(icon: Icon(Icons.manage_accounts_rounded), label: 'الموظفون'),
    ];

    if (index >= pages.length) index = 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
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

  @override
  void initState() {
    super.initState();
    future = loadDashboard();
  }

  Future<DashboardData> loadDashboard() async {
    final branches = await loadBranchesMap();
    final employeeRows = await supabase
        .from('ansar_employees')
        .select('id, display_name, full_name, username, branch_num')
        .eq('is_active', true);
    final employees = {
      for (final row in employeeRows)
        row['id'] as String: EmployeeLite.fromRow(row),
    };

    final now = DateTime.now();
    final todayStartUtc = DateTime(now.year, now.month, now.day).toUtc();
    final todayRows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .gte('check_in_at', todayStartUtc.toIso8601String())
        .order('check_in_at', ascending: false);

    final todayLogs = <TodayAttendance>[];
    for (final row in todayRows) {
      final employee = employees[row['employee_id']];
      if (employee == null) continue;
      final branchNum = (row['branch_num'] as num?)?.toInt() ?? employee.branchNum;
      todayLogs.add(
        TodayAttendance(
          employee: employee,
          branchName: branchLabel(branches, branchNum),
          checkIn: DateTime.parse(row['check_in_at'] as String).toLocal(),
          checkOut: row['check_out_at'] == null
              ? null
              : DateTime.parse(row['check_out_at'] as String).toLocal(),
          isOpen: row['status'] == 'open',
        ),
      );
    }

    final sinceUtc = now.subtract(const Duration(days: 30)).toUtc();
    final durationRows = await supabase
        .from('ansar_attendance_logs')
        .select()
        .gte('check_in_at', sinceUtc.toIso8601String());
    final hoursByEmployee = <String, double>{};
    final daysByEmployee = <String, Set<String>>{};
    for (final row in durationRows) {
      final employeeId = row['employee_id'] as String?;
      final checkInValue = row['check_in_at'] as String?;
      if (employeeId == null || checkInValue == null) continue;
      final checkIn = DateTime.parse(checkInValue).toLocal();
      final checkOut = row['check_out_at'] == null
          ? DateTime.now()
          : DateTime.parse(row['check_out_at'] as String).toLocal();
      final hours = checkOut.difference(checkIn).inMinutes / 60;
      if (hours <= 0 || hours > 24) continue;
      hoursByEmployee[employeeId] = (hoursByEmployee[employeeId] ?? 0) + hours;
      daysByEmployee.putIfAbsent(employeeId, () => <String>{}).add(formatDateKey(checkIn));
    }

    final topDurations = hoursByEmployee.entries
        .where((entry) => employees.containsKey(entry.key))
        .map(
          (entry) => EmployeeDuration(
            employee: employees[entry.key]!,
            hours: entry.value,
            days: daysByEmployee[entry.key]?.length ?? 0,
          ),
        )
        .toList()
      ..sort((a, b) => b.hours.compareTo(a.hours));

    return DashboardData(
      branches: branches,
      todayLogs: todayLogs,
      topDurations: topDurations.take(7).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => future = loadDashboard()),
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
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
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
              const SizedBox(height: 10),
              StatTile(
                title: 'إجمالي ساعات أعلى الموظفين خلال 30 يوم',
                value: '${data.totalHours30Days.toStringAsFixed(1)} ساعة',
                icon: Icons.bar_chart_rounded,
                color: const Color(0xff5b6f95),
              ),
              const SizedBox(height: 16),
              SectionHeader(
                title: 'الحضور اليوم',
                action: IconButton(
                  tooltip: 'تحديث',
                  onPressed: () => setState(() => future = loadDashboard()),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
              if (data.todayLogs.isEmpty)
                const EmptyState(
                  icon: Icons.event_busy_rounded,
                  text: 'لا يوجد تسجيل دخول لهذا اليوم بعد',
                )
              else
                ...data.todayLogs.map((log) => AttendanceListTile(log: log)),
              const SizedBox(height: 18),
              const SectionHeader(title: 'أطول دوام آخر 30 يوم'),
              if (data.topDurations.isEmpty)
                const EmptyState(
                  icon: Icons.insights_rounded,
                  text: 'ستظهر الإحصائيات بعد تسجيل الدوام',
                )
              else ...[
                SizedBox(height: 230, child: DurationChart(items: data.topDurations)),
                const SizedBox(height: 8),
                ...data.topDurations.map((item) => DurationListTile(item: item)),
              ],
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
      branches = await loadBranchesMap();
      final rows = await supabase
          .from('ansar_attendance_logs')
          .select()
          .eq('employee_id', widget.session.id)
          .eq('status', 'open')
          .order('check_in_at', ascending: false)
          .limit(1);
      setState(() {
        openLog = rows.isEmpty ? null : rows.first;
        loading = false;
      });
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
    if (error != null) {
      return ErrorState(message: error!, onRetry: loadOpenLog);
    }
    final isWorking = openLog != null;
    final branchName = branchLabel(branches, widget.session.branchNum);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Icon(
          isWorking ? Icons.work_history_rounded : Icons.work_off_rounded,
          size: 72,
          color: isWorking ? Colors.green : Colors.grey,
        ),
        const SizedBox(height: 12),
        Text(
          isWorking ? 'أنت داخل العمل الآن' : 'لم يتم تسجيل دخول مفتوح',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          branchName,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54),
        ),
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(message!, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: isWorking ? null : checkIn,
          icon: const Icon(Icons.login_rounded),
          label: const Text('دخول'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: isWorking ? checkOut : null,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('خروج'),
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

  @override
  void initState() {
    super.initState();
    employeesFuture = loadEmployees();
  }

  Future<EmployeesData> loadEmployees() async {
    final branches = await loadBranchesMap();
    final employees = await supabase
        .from('ansar_employees')
        .select()
        .order('created_at', ascending: false);
    return EmployeesData(
      branches: branches,
      employees: employees.cast<Map<String, dynamic>>(),
    );
  }

  Future<void> createEmployee(Map<int, BranchOption> branches) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => EmployeeDialog(branches: branches),
    );
    if (result == null) return;

    await supabase.from('ansar_employees').insert({
      ...result,
      'created_by': widget.session.id,
      'is_active': true,
    });
    setState(() => employeesFuture = loadEmployees());
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
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
                title: Text(employee['display_name'] ?? employee['full_name'] ?? ''),
                subtitle: Text('${branchLabel(data.branches, branchNum)} · ${employee['username']}'),
                trailing: Text(roleLabel(employee['role'] as String? ?? 'employee')),
              );
            },
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => createEmployee(data.branches),
            icon: const Icon(Icons.add_rounded),
            label: const Text('موظف'),
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
  const EmployeeDialog({super.key, required this.branches});

  final Map<int, BranchOption> branches;

  @override
  State<EmployeeDialog> createState() => _EmployeeDialogState();
}

class _EmployeeDialogState extends State<EmployeeDialog> {
  final name = TextEditingController();
  final username = TextEditingController();
  String role = 'employee';
  int? branchNum;

  @override
  void initState() {
    super.initState();
    if (widget.branches.isNotEmpty) {
      branchNum = widget.branches.keys.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة موظف'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم')),
            TextField(controller: username, decoration: const InputDecoration(labelText: 'اسم المستخدم')),
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
                DropdownMenuItem(value: 'admin', child: Text('مدير')),
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

class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'صفحة المناقلات هي المرحلة التالية: إنشاء طلب، إضافة كتب، موافقة الفرع الآخر، وتحديث حالة التحضير أو التوصيل.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'الدردشة جاهزة من ناحية الجداول. المرحلة التالية ربط الرسائل الحية والمحادثات العامة والخاصة.',
          textAlign: TextAlign.center,
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
      color: color.withValues(alpha: 0.09),
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

class AttendanceListTile extends StatelessWidget {
  const AttendanceListTile({super.key, required this.log});

  final TodayAttendance log;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: log.isOpen ? Colors.green.shade50 : Colors.grey.shade100,
          child: Icon(
            log.isOpen ? Icons.play_arrow_rounded : Icons.done_rounded,
            color: log.isOpen ? Colors.green : Colors.grey,
          ),
        ),
        title: Text(log.employee.name),
        subtitle: Text('${log.branchName} · دخول ${formatTime(log.checkIn)}'),
        trailing: Text(log.isOpen ? 'داخل' : 'خرج ${formatTime(log.checkOut!)}'),
      ),
    );
  }
}

class DurationChart extends StatelessWidget {
  const DurationChart({super.key, required this.items});

  final List<EmployeeDuration> items;

  @override
  Widget build(BuildContext context) {
    final maxHours = items.fold<double>(0, (max, item) => item.hours > max ? item.hours : max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 20, 10, 8),
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxHours <= 0 ? 1 : maxHours * 1.18,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 42,
                  getTitlesWidget: (value, meta) {
                    final index = value.toInt();
                    if (index < 0 || index >= items.length) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        shortName(items[index].employee.name),
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < items.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: items[i].hours,
                      color: i == 0 ? accentColor : brandColor,
                      width: 18,
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
      leading: const CircleAvatar(child: Icon(Icons.timer_rounded)),
      title: Text(item.employee.name),
      subtitle: Text('${item.days} أيام حضور'),
      trailing: Text('${item.hours.toStringAsFixed(1)} ساعة'),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 46, color: Colors.black38),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
        ],
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

Future<Map<int, BranchOption>> loadBranchesMap() async {
  final rows = await supabase.from('branches').select('sto_num, name').order('sto_num');
  final branches = <int, BranchOption>{};
  for (final row in rows) {
    final number = (row['sto_num'] as num?)?.toInt();
    if (number == null) continue;
    branches[number] = BranchOption(
      number: number,
      name: (row['name'] ?? 'فرع $number') as String,
    );
  }
  return branches;
}

String branchLabel(Map<int, BranchOption> branches, int branchNum) {
  return branches[branchNum]?.name ?? 'فرع رقم $branchNum';
}

String roleLabel(String role) {
  switch (role) {
    case 'admin':
      return 'مدير';
    case 'branch_manager':
      return 'مدير فرع';
    default:
      return 'موظف';
  }
}

String cleanError(Object? error) {
  return error.toString().replaceFirst('Exception: ', '');
}

String formatTime(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String formatDateKey(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String shortName(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return name;
  if (parts.length == 1) return parts.first;
  return '${parts[0]} ${parts[1]}';
}
