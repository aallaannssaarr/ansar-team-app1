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

class AnsarApp extends StatelessWidget {
  const AnsarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'فريق الأنصار',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff00796b)),
        useMaterial3: true,
        fontFamily: 'Roboto',
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
  int get branchNum => data['branch_num'] as int;
  String get role => data['role'] as String;
  bool get canManageEmployees => data['can_manage_employees'] == true;
  bool get canManageAllBranches => data['can_manage_all_branches'] == true;
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
      setState(() => error = e.toString().replaceFirst('Exception: ', ''));
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
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.groups_rounded, size: 72, color: Color(0xff00796b)),
                  const SizedBox(height: 16),
                  const Text(
                    'فريق الأنصار',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 32),
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

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.session});

  final EmployeeSession session;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _InfoCard(
          icon: Icons.store_rounded,
          title: 'الفرع',
          value: 'رقم ${session.branchNum}',
        ),
        _InfoCard(
          icon: Icons.verified_user_rounded,
          title: 'الصلاحية',
          value: session.role,
        ),
        const _InfoCard(
          icon: Icons.notifications_active_rounded,
          title: 'الإشعارات',
          value: 'جاهزة للربط مع Firebase Cloud Messaging',
        ),
        const _InfoCard(
          icon: Icons.search_rounded,
          title: 'الاستعلامات',
          value: 'سيتم نقل صفحات الاستعلامات الحالية إلى شاشات أصلية تدريجيًا',
        ),
      ],
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
  bool loading = true;
  String? message;

  @override
  void initState() {
    super.initState();
    loadOpenLog();
  }

  Future<void> loadOpenLog() async {
    setState(() => loading = true);
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
    final isWorking = openLog != null;

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
          isWorking ? 'أنت داخل العمل الآن' : 'لم يتم تسجيل دخول اليوم',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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
  late Future<List<dynamic>> employeesFuture;

  @override
  void initState() {
    super.initState();
    employeesFuture = loadEmployees();
  }

  Future<List<dynamic>> loadEmployees() {
    return supabase
        .from('ansar_employees')
        .select()
        .order('created_at', ascending: false);
  }

  Future<void> createEmployee() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const EmployeeDialog(),
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
    return Scaffold(
      body: FutureBuilder<List<dynamic>>(
        future: employeesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final employees = snapshot.data!;
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: employees.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final employee = employees[i] as Map<String, dynamic>;
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
                title: Text(employee['display_name'] ?? employee['full_name'] ?? ''),
                subtitle: Text('فرع ${employee['branch_num']} · ${employee['username']}'),
                trailing: Text(employee['role'] ?? ''),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: createEmployee,
        icon: const Icon(Icons.add_rounded),
        label: const Text('موظف'),
      ),
    );
  }
}

class EmployeeDialog extends StatefulWidget {
  const EmployeeDialog({super.key});

  @override
  State<EmployeeDialog> createState() => _EmployeeDialogState();
}

class _EmployeeDialogState extends State<EmployeeDialog> {
  final name = TextEditingController();
  final username = TextEditingController();
  final branch = TextEditingController();
  String role = 'employee';

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
            TextField(
              controller: branch,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'رقم الفرع'),
            ),
            DropdownButtonFormField<String>(
              initialValue: role,
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
          onPressed: () {
            Navigator.pop(context, {
              'full_name': name.text.trim(),
              'display_name': name.text.trim(),
              'username': username.text.trim(),
              'branch_num': int.tryParse(branch.text.trim()) ?? 1,
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
          'صفحة المناقلات ستكون المرحلة التالية: إنشاء طلب، إضافة كتب، موافقة الفرع الآخر، وتحديث الحالة.',
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
          'الدردشة جاهزة من ناحية الجداول. المرحلة التالية ربط الرسائل الحية واشتراكات Supabase Realtime.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: const Color(0xff00796b)),
        title: Text(title),
        subtitle: Text(value),
      ),
    );
  }
}
