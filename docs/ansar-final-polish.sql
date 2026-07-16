-- التحسينات النهائية الآمنة لتطبيق فريق الأنصار.
-- يمكن تنفيذ الملف أكثر من مرة دون حذف أي بيانات أو سجلات قديمة.

begin;

-- المدير العام يدير جميع الفروع ولا يرتبط بفرع واحد.
alter table public.ansar_employees
  alter column branch_num drop not null;

update public.ansar_employees
set branch_num = null
where branch_num is not null
  and (
    role = 'admin'
    or coalesce(can_manage_all_branches, false) = true
  );

-- استبعاد المدير العام من تذكيرات الدوام، مع إبقاء سجلاته القديمة كما هي.
create or replace function public.ansar_generate_attendance_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  local_now timestamp := timezone('Asia/Damascus', now());
  local_date date := timezone('Asia/Damascus', now())::date;
  local_time time := timezone('Asia/Damascus', now())::time;
  day_start timestamptz := local_date::timestamp at time zone 'Asia/Damascus';
  day_end timestamptz := (local_date + 1)::timestamp at time zone 'Asia/Damascus';
  inserted_count integer := 0;
  affected_count integer := 0;
begin
  if extract(isodow from local_now)::integer = 5 then
    return 0;
  end if;

  if local_time >= time '09:30' and local_time < time '22:00' then
    with candidates as (
      select e.id::text as employee_id, e.branch_num
      from public.ansar_employees e
      where coalesce(e.is_active, true) = true
        and e.branch_num is not null
        and coalesce(e.role, 'employee') <> 'admin'
        and coalesce(e.can_manage_all_branches, false) = false
        and not exists (
          select 1
          from public.ansar_attendance_logs a
          where a.employee_id::text = e.id::text
            and a.check_in_at >= day_start
            and a.check_in_at < day_end
        )
    ), reserved as (
      insert into public.ansar_attendance_reminder_runs (
        employee_id, reminder_date, reminder_type
      )
      select employee_id, local_date, 'missing_check_in'
      from candidates
      on conflict do nothing
      returning employee_id
    ), queued as (
      insert into public.ansar_notification_queue (
        employee_id, title, body, data, status, notification_key
      )
      select
        r.employee_id,
        'تذكير بتسجيل الدوام',
        'لم تسجل دخولك اليوم بعد. اضغط هنا لتسجيل وقت الدوام.',
        jsonb_build_object(
          'type', 'attendance_reminder_check_in',
          'route', 'attendance',
          'employee_id', r.employee_id
        ),
        'pending',
        'attendance:check-in:' || local_date::text || ':' || r.employee_id
      from reserved r
      on conflict do nothing
      returning id::text, employee_id::text
    )
    update public.ansar_attendance_reminder_runs runs
    set notification_id = queued.id
    from queued
    where runs.employee_id = queued.employee_id
      and runs.reminder_date = local_date
      and runs.reminder_type = 'missing_check_in';
    get diagnostics inserted_count = row_count;
  end if;

  if local_time >= time '22:00' then
    with candidates as (
      select distinct e.id::text as employee_id
      from public.ansar_employees e
      join public.ansar_attendance_logs a
        on a.employee_id::text = e.id::text
      where coalesce(e.is_active, true) = true
        and e.branch_num is not null
        and coalesce(e.role, 'employee') <> 'admin'
        and coalesce(e.can_manage_all_branches, false) = false
        and a.status = 'open'
        and a.check_out_at is null
        and a.check_in_at < day_end
    ), reserved as (
      insert into public.ansar_attendance_reminder_runs (
        employee_id, reminder_date, reminder_type
      )
      select employee_id, local_date, 'open_shift'
      from candidates
      on conflict do nothing
      returning employee_id
    ), queued as (
      insert into public.ansar_notification_queue (
        employee_id, title, body, data, status, notification_key
      )
      select
        r.employee_id,
        'تذكير بتسجيل الخروج',
        'ما زال دوامك مفتوحاً. اضغط هنا لمراجعة وقت الخروج.',
        jsonb_build_object(
          'type', 'attendance_reminder_check_out',
          'route', 'attendance',
          'employee_id', r.employee_id
        ),
        'pending',
        'attendance:check-out:' || local_date::text || ':' || r.employee_id
      from reserved r
      on conflict do nothing
      returning id::text, employee_id::text
    )
    update public.ansar_attendance_reminder_runs runs
    set notification_id = queued.id
    from queued
    where runs.employee_id = queued.employee_id
      and runs.reminder_date = local_date
      and runs.reminder_type = 'open_shift';
    get diagnostics affected_count = row_count;
    inserted_count := inserted_count + affected_count;
  end if;

  return inserted_count;
end;
$$;

grant execute on function public.ansar_generate_attendance_reminders()
to anon, authenticated, service_role;

commit;
