-- البنية الموحدة لتطوير الإشعارات والدوام والمناقلات والدردشة.
-- هذا الملف إضافي وقابل لإعادة التنفيذ. لا يحذف ولا يعيد تسمية أي جدول قائم.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- الأجهزة وتسليم الإشعارات
-- ---------------------------------------------------------------------------

create table if not exists public.ansar_device_installations (
  id uuid primary key default extensions.gen_random_uuid(),
  installation_id text not null unique,
  employee_id text not null,
  platform text not null default 'android',
  device_name text,
  app_version text,
  permission_status text not null default 'unknown',
  preferred_provider text not null default 'firebase',
  fcm_token text,
  pushy_token text,
  firebase_failures integer not null default 0,
  pushy_failures integer not null default 0,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  last_success_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists ansar_installations_fcm_token_uidx
  on public.ansar_device_installations (fcm_token)
  where fcm_token is not null;

create unique index if not exists ansar_installations_pushy_token_uidx
  on public.ansar_device_installations (pushy_token)
  where pushy_token is not null;

create index if not exists ansar_installations_employee_active_idx
  on public.ansar_device_installations (employee_id, is_active, last_seen_at desc);

alter table public.ansar_notification_queue
  add column if not exists notification_key text,
  add column if not exists attempts integer not null default 0,
  add column if not exists next_attempt_at timestamptz,
  add column if not exists processed_at timestamptz;

create unique index if not exists ansar_notification_queue_key_uidx
  on public.ansar_notification_queue (notification_key)
  where notification_key is not null;

create table if not exists public.ansar_notification_deliveries (
  id uuid primary key default extensions.gen_random_uuid(),
  notification_id text not null,
  installation_id uuid not null references public.ansar_device_installations(id) on delete cascade,
  employee_id text not null,
  provider text,
  status text not null default 'pending',
  attempts integer not null default 0,
  next_attempt_at timestamptz,
  provider_message_id text,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (notification_id, installation_id)
);

create index if not exists ansar_notification_deliveries_retry_idx
  on public.ansar_notification_deliveries (status, next_attempt_at, created_at);

create table if not exists public.ansar_notification_receipts (
  notification_id text not null,
  employee_id text not null,
  opened_at timestamptz,
  synced_at timestamptz not null default now(),
  primary key (notification_id, employee_id)
);

-- استيراد رموز Firebase القديمة من دون تعديل الجدول القديم.
do $$
begin
  if to_regclass('public.ansar_device_tokens') is not null then
    execute $migration$
      insert into public.ansar_device_installations (
        installation_id, employee_id, platform, device_name, fcm_token,
        is_active, last_seen_at, preferred_provider
      )
      select distinct on (legacy.row_data->>'token')
        'legacy:' || (legacy.row_data->>'id'),
        legacy.row_data->>'employee_id',
        coalesce(nullif(legacy.row_data->>'platform', ''), 'android'),
        nullif(legacy.row_data->>'device_name', ''),
        legacy.row_data->>'token',
        coalesce(nullif(legacy.row_data->>'is_active', '')::boolean, true),
        coalesce(nullif(legacy.row_data->>'last_seen_at', '')::timestamptz, now()),
        'firebase'
      from (
        select to_jsonb(token_row) as row_data
        from public.ansar_device_tokens token_row
      ) legacy
      where nullif(legacy.row_data->>'token', '') is not null
        and nullif(legacy.row_data->>'employee_id', '') is not null
      order by
        legacy.row_data->>'token',
        nullif(legacy.row_data->>'last_seen_at', '')::timestamptz desc nulls last
      on conflict (installation_id) do update set
        employee_id = excluded.employee_id,
        fcm_token = excluded.fcm_token,
        is_active = excluded.is_active,
        last_seen_at = excluded.last_seen_at,
        updated_at = now()
    $migration$;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- الدوام بأثر رجعي مع قواعد سلامة خادمية
-- ---------------------------------------------------------------------------

alter table public.ansar_attendance_logs
  add column if not exists check_in_recorded_at timestamptz,
  add column if not exists check_out_recorded_at timestamptz,
  add column if not exists check_in_is_backdated boolean not null default false,
  add column if not exists check_out_is_backdated boolean not null default false,
  add column if not exists check_in_note text,
  add column if not exists check_out_note text;

update public.ansar_attendance_logs
set check_in_recorded_at = coalesce(check_in_recorded_at, check_in_at, now())
where check_in_recorded_at is null;

alter table public.ansar_attendance_logs
  alter column check_in_recorded_at set default now();

create or replace function public.ansar_validate_attendance_log()
returns trigger
language plpgsql
as $$
begin
  perform 1
  from public.ansar_employees employee
  where employee.id::text = new.employee_id::text
  for update;
  if new.check_in_at is null then
    raise exception 'يجب تحديد وقت الدخول';
  end if;
  if new.check_in_at > now() + interval '2 minutes' then
    raise exception 'لا يمكن تسجيل وقت دخول مستقبلي';
  end if;
  if new.check_out_at is not null and new.check_out_at > now() + interval '2 minutes' then
    raise exception 'لا يمكن تسجيل وقت خروج مستقبلي';
  end if;
  if new.check_out_at is not null and new.check_out_at < new.check_in_at then
    raise exception 'وقت الخروج يجب أن يكون بعد وقت الدخول';
  end if;
  if exists (
    select 1
    from public.ansar_attendance_logs other
    where other.employee_id::text = new.employee_id::text
      and other.id::text <> new.id::text
      and tstzrange(
        other.check_in_at,
        coalesce(other.check_out_at, 'infinity'::timestamptz),
        '[)'
      ) && tstzrange(
        new.check_in_at,
        coalesce(new.check_out_at, 'infinity'::timestamptz),
        '[)'
      )
  ) then
    raise exception 'يتداخل هذا الوقت مع دوام مسجل مسبقاً';
  end if;
  return new;
end;
$$;

drop trigger if exists ansar_validate_attendance_log_trigger on public.ansar_attendance_logs;
create trigger ansar_validate_attendance_log_trigger
before insert or update of check_in_at, check_out_at, employee_id
on public.ansar_attendance_logs
for each row execute function public.ansar_validate_attendance_log();

create table if not exists public.ansar_attendance_reminder_runs (
  employee_id text not null,
  reminder_date date not null,
  reminder_type text not null,
  notification_id text,
  created_at timestamptz not null default now(),
  primary key (employee_id, reminder_date, reminder_type)
);

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
  -- الجمعة عطلة للتذكيرات.
  if extract(isodow from local_now)::integer = 5 then
    return 0;
  end if;

  if local_time >= time '09:30' and local_time < time '22:00' then
    with candidates as (
      select e.id::text as employee_id, e.branch_num
      from public.ansar_employees e
      where coalesce(e.is_active, true) = true
        and not exists (
          select 1 from public.ansar_attendance_logs a
          where a.employee_id::text = e.id::text
            and a.check_in_at >= day_start and a.check_in_at < day_end
        )
    ), reserved as (
      insert into public.ansar_attendance_reminder_runs (employee_id, reminder_date, reminder_type)
      select employee_id, local_date, 'missing_check_in' from candidates
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
      join public.ansar_attendance_logs a on a.employee_id::text = e.id::text
      where coalesce(e.is_active, true) = true
        and a.status = 'open'
        and a.check_out_at is null
        and a.check_in_at < day_end
    ), reserved as (
      insert into public.ansar_attendance_reminder_runs (employee_id, reminder_date, reminder_type)
      select employee_id, local_date, 'open_shift' from candidates
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

-- ---------------------------------------------------------------------------
-- استلام المناقلات
-- ---------------------------------------------------------------------------

alter table public.ansar_transfer_orders
  add column if not exists received_at timestamptz,
  add column if not exists received_by text,
  add column if not exists receipt_note text,
  add column if not exists has_receipt_discrepancy boolean not null default false;

alter table public.ansar_transfer_order_items
  add column if not exists received_quantity numeric,
  add column if not exists damaged_quantity numeric,
  add column if not exists receipt_note text,
  add column if not exists received_at timestamptz,
  add column if not exists received_by text;

create or replace function public.ansar_confirm_transfer_receipt(
  p_order_id text,
  p_employee_id text,
  p_items jsonb,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  order_row public.ansar_transfer_orders%rowtype;
  employee_branch integer;
  employee_role text;
  item_count integer;
  reviewed_count integer;
  has_difference boolean;
begin
  select * into order_row
  from public.ansar_transfer_orders
  where id::text = p_order_id
  for update;

  if not found then raise exception 'المناقلة غير موجودة'; end if;
  if order_row.status <> 'in_delivery' then
    raise exception 'لا يمكن تأكيد الاستلام قبل بدء التوصيل';
  end if;

  select branch_num, role into employee_branch, employee_role
  from public.ansar_employees
  where id::text = p_employee_id and coalesce(is_active, true) = true;

  if employee_role is null or employee_branch is distinct from order_row.from_branch_num then
    raise exception 'تأكيد الاستلام متاح للفرع الطالب فقط';
  end if;

  select count(*) into item_count
  from public.ansar_transfer_order_items
  where order_id::text = p_order_id;

  select count(distinct payload.value->>'item_id') into reviewed_count
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) payload(value)
  join public.ansar_transfer_order_items item
    on item.id::text = payload.value->>'item_id'
   and item.order_id::text = p_order_id;
  if reviewed_count <> item_count
     or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) <> item_count then
    raise exception 'يجب مراجعة جميع بنود المناقلة';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) payload
    join public.ansar_transfer_order_items item
      on item.id::text = payload->>'item_id'
    where item.order_id::text = p_order_id
      and (
        coalesce((payload->>'received_quantity')::numeric, 0) < 0
        or coalesce((payload->>'damaged_quantity')::numeric, 0) < 0
        or coalesce((payload->>'received_quantity')::numeric, 0)
          + coalesce((payload->>'damaged_quantity')::numeric, 0)
          > coalesce(item.approved_quantity, 0)
      )
  ) then
    raise exception 'الكميات المستلمة والتالفة لا يجوز أن تتجاوز الكمية المرسلة';
  end if;

  update public.ansar_transfer_order_items item
  set
    received_quantity = coalesce((payload.value->>'received_quantity')::numeric, 0),
    damaged_quantity = coalesce((payload.value->>'damaged_quantity')::numeric, 0),
    receipt_note = nullif(payload.value->>'note', ''),
    received_at = now(),
    received_by = p_employee_id
  from jsonb_array_elements(p_items) payload(value)
  where item.order_id::text = p_order_id
    and item.id::text = payload.value->>'item_id';

  select exists (
    select 1 from public.ansar_transfer_order_items item
    where item.order_id::text = p_order_id
      and (
        coalesce(item.damaged_quantity, 0) > 0
        or coalesce(item.received_quantity, 0) < coalesce(item.approved_quantity, 0)
        or item.receipt_note is not null
      )
  ) into has_difference;

  update public.ansar_transfer_orders
  set
    status = 'received',
    received_at = now(),
    received_by = p_employee_id,
    receipt_note = nullif(p_note, ''),
    has_receipt_discrepancy = has_difference
  where id::text = p_order_id;

  insert into public.ansar_order_events (
    order_id, employee_id, event_type, old_status, new_status, note
  ) values (
    order_row.id, p_employee_id, 'receipt_confirmed', 'in_delivery', 'received',
    case when has_difference then 'تم الاستلام مع ملاحظات' else 'تم الاستلام كاملاً' end
  );

  return jsonb_build_object('received', true, 'has_difference', has_difference);
end;
$$;

create or replace function public.ansar_validate_transfer_status_transition()
returns trigger
language plpgsql
as $$
declare
  allowed boolean := false;
begin
  if old.status is not distinct from new.status then return new; end if;
  allowed := case old.status
    when 'draft' then new.status = 'submitted'
    when 'submitted' then new.status in ('approved', 'partially_available', 'rejected', 'cancelled')
    when 'approved' then new.status in ('partially_available', 'preparing', 'rejected', 'cancelled')
    when 'partially_available' then new.status in ('preparing', 'rejected', 'cancelled')
    when 'preparing' then new.status in ('in_delivery', 'cancelled')
    when 'in_delivery' then new.status = 'received'
    else false
  end;
  if not allowed then raise exception 'انتقال حالة المناقلة غير مسموح'; end if;

  if new.status = 'in_delivery' and (
    not exists (
      select 1 from public.ansar_transfer_order_items item
      where item.order_id::text = new.id::text
    ) or exists (
      select 1 from public.ansar_transfer_order_items item
      where item.order_id::text = new.id::text
        and (coalesce(item.item_status, 'requested') = 'requested' or item.approved_quantity is null)
    )
  ) then
    raise exception 'يجب معالجة جميع البنود قبل بدء التوصيل';
  end if;
  return new;
end;
$$;

drop trigger if exists ansar_validate_transfer_status_trigger on public.ansar_transfer_orders;
create trigger ansar_validate_transfer_status_trigger
before update of status on public.ansar_transfer_orders
for each row execute function public.ansar_validate_transfer_status_transition();

-- ---------------------------------------------------------------------------
-- الدردشة المتقدمة
-- ---------------------------------------------------------------------------

alter table public.ansar_chat_participants
  add column if not exists is_muted boolean not null default false,
  add column if not exists is_pinned boolean not null default false,
  add column if not exists muted_until timestamptz,
  add column if not exists is_archived boolean not null default false,
  add column if not exists archived_at timestamptz,
  add column if not exists last_delivered_at timestamptz,
  add column if not exists last_read_at timestamptz,
  add column if not exists last_read_message_id text;

alter table public.ansar_chat_threads
  add column if not exists description text,
  add column if not exists avatar_url text;

alter table public.ansar_chat_messages
  add column if not exists message_type text not null default 'text',
  add column if not exists reply_to_id text,
  add column if not exists edited_at timestamptz,
  add column if not exists edited_by text,
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by text,
  add column if not exists forwarded_from_id text,
  add column if not exists attachments jsonb not null default '[]'::jsonb,
  add column if not exists transfer_order_id text;

alter table public.ansar_employees
  add column if not exists last_seen_at timestamptz;

create table if not exists public.ansar_chat_message_receipts (
  message_id text not null,
  thread_id text not null,
  employee_id text not null,
  status text not null default 'sent',
  sent_at timestamptz not null default now(),
  delivered_at timestamptz,
  read_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (message_id, employee_id)
);

create index if not exists ansar_chat_receipts_employee_status_idx
  on public.ansar_chat_message_receipts (employee_id, status, thread_id);

create table if not exists public.ansar_chat_message_hidden (
  employee_id text not null,
  message_id text not null,
  hidden_at timestamptz not null default now(),
  primary key (employee_id, message_id)
);

create index if not exists ansar_chat_messages_reply_to_idx
  on public.ansar_chat_messages (reply_to_id)
  where reply_to_id is not null;

create index if not exists ansar_chat_messages_forwarded_from_idx
  on public.ansar_chat_messages (forwarded_from_id)
  where forwarded_from_id is not null;

create index if not exists ansar_chat_participants_employee_thread_idx
  on public.ansar_chat_participants (employee_id, thread_id);

create or replace function public.ansar_create_chat_receipts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ansar_chat_message_receipts (
    message_id, thread_id, employee_id, status, sent_at
  )
  select new.id::text, new.thread_id::text, recipients.employee_id, 'sent', coalesce(new.created_at, now())
  from (
    select e.id::text as employee_id
    from public.ansar_employees e
    join public.ansar_chat_threads t on t.id::text = new.thread_id::text
    where t.thread_type = 'general'
      and coalesce(e.is_active, true) = true
      and e.id::text <> new.sender_id::text
    union
    select p.employee_id::text
    from public.ansar_chat_participants p
    join public.ansar_chat_threads t on t.id::text = new.thread_id::text
    where t.thread_type <> 'general'
      and p.thread_id::text = new.thread_id::text
      and p.employee_id::text <> new.sender_id::text
  ) recipients
  on conflict do nothing;

  update public.ansar_chat_participants
  set is_archived = false, archived_at = null
  where thread_id::text = new.thread_id::text
    and employee_id::text <> new.sender_id::text;
  return new;
end;
$$;

drop trigger if exists ansar_create_chat_receipts_trigger on public.ansar_chat_messages;
create trigger ansar_create_chat_receipts_trigger
after insert on public.ansar_chat_messages
for each row execute function public.ansar_create_chat_receipts();

create or replace function public.ansar_mark_chat_delivered(p_employee_id text, p_thread_id text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare changed integer;
begin
  update public.ansar_chat_message_receipts
  set status = case when status = 'read' then 'read' else 'delivered' end,
      delivered_at = coalesce(delivered_at, now()),
      updated_at = now()
  where employee_id = p_employee_id
    and thread_id = p_thread_id
    and status = 'sent';
  get diagnostics changed = row_count;
  update public.ansar_chat_participants
  set last_delivered_at = now()
  where employee_id::text = p_employee_id and thread_id::text = p_thread_id;
  return changed;
end;
$$;

create or replace function public.ansar_mark_chat_read(p_employee_id text, p_thread_id text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare changed integer;
begin
  update public.ansar_chat_message_receipts
  set status = 'read',
      delivered_at = coalesce(delivered_at, now()),
      read_at = coalesce(read_at, now()),
      updated_at = now()
  where employee_id = p_employee_id
    and thread_id = p_thread_id
    and status <> 'read';
  get diagnostics changed = row_count;
  update public.ansar_chat_participants
  set last_read_at = now(), is_archived = false, archived_at = null
  where employee_id::text = p_employee_id and thread_id::text = p_thread_id;
  return changed;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit)
values ('ansar-chat', 'ansar-chat', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists "ansar chat attachments read" on storage.objects;
create policy "ansar chat attachments read"
on storage.objects for select
using (bucket_id = 'ansar-chat');

drop policy if exists "ansar chat attachments upload" on storage.objects;
create policy "ansar chat attachments upload"
on storage.objects for insert
with check (bucket_id = 'ansar-chat');

drop policy if exists "ansar chat attachments delete" on storage.objects;
create policy "ansar chat attachments delete"
on storage.objects for delete
using (bucket_id = 'ansar-chat');

-- ---------------------------------------------------------------------------
-- الصلاحيات وRealtime
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on table
  public.ansar_device_installations,
  public.ansar_notification_deliveries,
  public.ansar_notification_receipts,
  public.ansar_attendance_reminder_runs,
  public.ansar_chat_message_receipts,
  public.ansar_chat_message_hidden
to anon, authenticated, service_role;

grant execute on function public.ansar_generate_attendance_reminders() to anon, authenticated, service_role;
grant execute on function public.ansar_confirm_transfer_receipt(text, text, jsonb, text) to anon, authenticated, service_role;
grant execute on function public.ansar_mark_chat_delivered(text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_mark_chat_read(text, text) to anon, authenticated, service_role;

alter table public.ansar_device_installations replica identity full;
alter table public.ansar_notification_deliveries replica identity full;
alter table public.ansar_chat_message_receipts replica identity full;
alter table public.ansar_attendance_logs replica identity full;
alter table public.ansar_transfer_orders replica identity full;
alter table public.ansar_transfer_order_items replica identity full;
alter table public.ansar_order_events replica identity full;
alter table public.ansar_chat_threads replica identity full;
alter table public.ansar_chat_participants replica identity full;
alter table public.ansar_chat_messages replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.ansar_device_installations;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_notification_deliveries;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_message_receipts;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_attendance_logs;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_transfer_orders;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_transfer_order_items;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_order_events;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_threads;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_participants;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_messages;
exception when duplicate_object then null; end $$;
