-- Team Al Ansar local-first synchronization upgrade.
-- Safe to run more than once. It only adds compatible columns, indexes,
-- helper tables and replaceable RPC functions. No existing row is deleted.

create extension if not exists pgcrypto;

alter table public.ansar_attendance_logs
  add column if not exists client_action_id text,
  add column if not exists sync_version bigint not null default 1,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists check_in_recorded_at timestamptz,
  add column if not exists check_out_recorded_at timestamptz,
  add column if not exists check_in_is_backdated boolean not null default false,
  add column if not exists check_out_is_backdated boolean not null default false,
  add column if not exists check_in_note text,
  add column if not exists check_out_note text;

alter table public.ansar_chat_messages
  add column if not exists client_action_id text,
  add column if not exists sync_version bigint not null default 1,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists message_type text not null default 'text',
  add column if not exists attachments jsonb not null default '[]'::jsonb,
  add column if not exists reply_to_id text,
  add column if not exists transfer_order_id text;

alter table public.ansar_chat_participants
  add column if not exists is_muted boolean not null default false,
  add column if not exists muted_until timestamptz,
  add column if not exists is_pinned boolean not null default false,
  add column if not exists is_archived boolean not null default false,
  add column if not exists last_read_at timestamptz;

alter table public.ansar_transfer_orders
  add column if not exists client_action_id text,
  add column if not exists sync_version bigint not null default 1,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists received_at timestamptz,
  add column if not exists received_by text,
  add column if not exists receipt_note text,
  add column if not exists has_receipt_discrepancy boolean not null default false;

alter table public.ansar_transfer_order_items
  add column if not exists client_action_id text,
  add column if not exists sync_version bigint not null default 1,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists received_quantity numeric,
  add column if not exists damaged_quantity numeric,
  add column if not exists receipt_note text,
  add column if not exists received_at timestamptz,
  add column if not exists received_by text;

alter table public.ansar_notification_queue
  add column if not exists notification_key text;

create unique index if not exists ansar_attendance_client_action_uidx
  on public.ansar_attendance_logs (client_action_id) where client_action_id is not null;
create unique index if not exists ansar_chat_messages_client_action_uidx
  on public.ansar_chat_messages (client_action_id) where client_action_id is not null;
create unique index if not exists ansar_transfer_orders_client_action_uidx
  on public.ansar_transfer_orders (client_action_id) where client_action_id is not null;
create unique index if not exists ansar_transfer_items_client_action_uidx
  on public.ansar_transfer_order_items (client_action_id) where client_action_id is not null;
create index if not exists ansar_attendance_sync_idx
  on public.ansar_attendance_logs (updated_at, id);
create index if not exists ansar_chat_messages_sync_idx
  on public.ansar_chat_messages (updated_at, id);
create index if not exists ansar_transfer_orders_sync_idx
  on public.ansar_transfer_orders (updated_at, id);
create index if not exists ansar_transfer_items_sync_idx
  on public.ansar_transfer_order_items (updated_at, id);
create index if not exists ansar_notification_queue_key_idx
  on public.ansar_notification_queue (notification_key) where notification_key is not null;

alter table public.ansar_transfer_orders
  drop constraint if exists ansar_transfer_orders_status_check;
alter table public.ansar_transfer_orders
  add constraint ansar_transfer_orders_status_check
  check (status in (
    'draft', 'submitted', 'approved', 'partially_available', 'preparing',
    'in_delivery', 'received', 'completed', 'rejected', 'cancelled'
  )) not valid;

alter table public.ansar_chat_messages
  drop constraint if exists ansar_chat_messages_message_type_check;
alter table public.ansar_chat_messages
  add constraint ansar_chat_messages_message_type_check
  check (message_type in ('text', 'attachment', 'transfer', 'forwarded', 'system')) not valid;

create table if not exists public.ansar_client_actions (
  action_id text primary key,
  employee_id text not null,
  action_type text not null,
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists ansar_client_actions_employee_created_idx
  on public.ansar_client_actions (employee_id, created_at desc);

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

insert into storage.buckets (id, name, public, file_size_limit)
values ('ansar-chat', 'ansar-chat', false, 10485760)
on conflict (id) do update
set public = false, file_size_limit = 10485760;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'ansar chat read'
  ) then
    create policy "ansar chat read" on storage.objects
      for select to anon, authenticated
      using (bucket_id = 'ansar-chat');
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'ansar chat upload'
  ) then
    create policy "ansar chat upload" on storage.objects
      for insert to anon, authenticated
      with check (bucket_id = 'ansar-chat');
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'ansar chat update'
  ) then
    create policy "ansar chat update" on storage.objects
      for update to anon, authenticated
      using (bucket_id = 'ansar-chat')
      with check (bucket_id = 'ansar-chat');
  end if;
end;
$$;

create or replace function public.ansar_touch_sync_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    new.sync_version := coalesce(old.sync_version, 0) + 1;
  end if;
  return new;
end;
$$;

do $$
declare
  table_name text;
  trigger_name text;
begin
  foreach table_name in array array[
    'ansar_attendance_logs', 'ansar_chat_messages',
    'ansar_transfer_orders', 'ansar_transfer_order_items'
  ] loop
    trigger_name := table_name || '_sync_touch_trigger';
    execute format('drop trigger if exists %I on public.%I', trigger_name, table_name);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.ansar_touch_sync_updated_at()',
      trigger_name,
      table_name
    );
  end loop;
end;
$$;

create or replace function public.ansar_apply_offline_action(
  p_action_id text,
  p_employee_id text,
  p_action_type text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  employee_row public.ansar_employees%rowtype;
  attendance_row public.ansar_attendance_logs%rowtype;
  message_row public.ansar_chat_messages%rowtype;
  order_row public.ansar_transfer_orders%rowtype;
  item_row public.ansar_transfer_order_items%rowtype;
  created_order public.ansar_transfer_orders%rowtype;
  created_message public.ansar_chat_messages%rowtype;
  thread_row public.ansar_chat_threads%rowtype;
  item_value jsonb;
  existing_result jsonb;
  result_value jsonb := '{}'::jsonb;
  expected_version bigint;
  reviewed_count integer := 0;
  item_count integer := 0;
  has_difference boolean := false;
  sender_name text;
  sender_avatar_url text;
  from_branch_name text;
  to_branch_name text;
  order_label text;
  status_text text;
  action_time timestamptz;
  action_time_text text;
begin
  if p_action_id is null or btrim(p_action_id) = '' then
    raise exception 'client_action_id is required';
  end if;

  select * into employee_row
  from public.ansar_employees
  where id::text = p_employee_id and coalesce(is_active, true) = true;
  if not found then raise exception 'الحساب غير موجود أو غير نشط'; end if;
  sender_name := coalesce(nullif(employee_row.display_name, ''), nullif(employee_row.full_name, ''), 'موظف');
  sender_avatar_url := employee_row.avatar_url;

  select result into existing_result
  from public.ansar_client_actions
  where action_id = p_action_id;
  if found and existing_result is not null then
    return existing_result || jsonb_build_object('duplicate', true);
  elsif found then
    raise exception 'العملية قيد التنفيذ، ستتم إعادة المحاولة تلقائياً';
  end if;

  insert into public.ansar_client_actions(action_id, employee_id, action_type)
  values (p_action_id, p_employee_id, p_action_type)
  on conflict (action_id) do nothing;
  if not found then
    select result into existing_result
    from public.ansar_client_actions
    where action_id = p_action_id;
    if existing_result is not null then
      return existing_result || jsonb_build_object('duplicate', true);
    end if;
    raise exception 'العملية قيد التنفيذ، ستتم إعادة المحاولة تلقائياً';
  end if;

  if p_action_type = 'attendance_check_in' then
    attendance_row := jsonb_populate_record(
      null::public.ansar_attendance_logs,
      coalesce(p_payload->'values', p_payload)
    );
    attendance_row.employee_id := employee_row.id;
    attendance_row.client_action_id := p_action_id;
    if attendance_row.check_in_at is null then raise exception 'وقت الدخول مطلوب'; end if;
    if attendance_row.check_in_at > now() then raise exception 'لا يمكن تسجيل وقت مستقبلي'; end if;
    if exists (
      select 1 from public.ansar_attendance_logs log
      where log.employee_id::text = p_employee_id and log.status = 'open'
    ) then raise exception 'يوجد دوام مفتوح لهذا الموظف'; end if;
    insert into public.ansar_attendance_logs(
      employee_id, branch_num, check_in_at, check_in_recorded_at,
      check_in_is_backdated, check_in_note, status, client_action_id,
      sync_version, updated_at
    ) values (
      attendance_row.employee_id, attendance_row.branch_num,
      attendance_row.check_in_at, coalesce(attendance_row.check_in_recorded_at, now()),
      coalesce(attendance_row.check_in_is_backdated, false), attendance_row.check_in_note,
      'open', p_action_id, 1, now()
    ) returning id::text into sender_name;
    result_value := jsonb_build_object('id', sender_name, 'type', p_action_type);

    action_time := attendance_row.check_in_at;
    action_time_text := to_char(action_time at time zone 'Asia/Damascus', 'HH12:MI') ||
      case when extract(hour from action_time at time zone 'Asia/Damascus') < 12 then ' ص' else ' م' end;
    sender_name := coalesce(nullif(employee_row.display_name, ''), nullif(employee_row.full_name, ''), 'موظف');
    begin
      insert into public.ansar_notification_queue(
        employee_id, title, body, data, status, notification_key
      )
      select
        recipient.id::text,
        'تسجيل دخول دوام',
        sender_name || ' سجل الدخول الساعة ' || action_time_text ||
          case when coalesce(attendance_row.check_in_is_backdated, false) then ' (سُجل لاحقاً)' else '' end,
        jsonb_strip_nulls(jsonb_build_object(
          'type', 'attendance_check_in', 'route', 'attendance',
          'attendance_id', result_value->>'id',
          'sender_id', employee_row.id::text,
          'sender_name', sender_name,
          'sender_avatar_url', sender_avatar_url,
          'effective_at', action_time,
          'is_backdated', coalesce(attendance_row.check_in_is_backdated, false)
        )),
        'pending',
        'offline:' || p_action_id || ':' || recipient.id::text
      from public.ansar_employees recipient
      where coalesce(recipient.is_active, true) = true
        and recipient.id::text <> p_employee_id;
    exception when others then
      null;
    end;

  elsif p_action_type = 'attendance_check_out' then
    attendance_row := jsonb_populate_record(
      null::public.ansar_attendance_logs,
      coalesce(p_payload->'values', '{}'::jsonb)
    );
    if attendance_row.check_out_at is null then raise exception 'وقت الخروج مطلوب'; end if;
    update public.ansar_attendance_logs log set
      check_out_at = attendance_row.check_out_at,
      check_out_recorded_at = coalesce(attendance_row.check_out_recorded_at, now()),
      check_out_is_backdated = coalesce(attendance_row.check_out_is_backdated, false),
      check_out_note = attendance_row.check_out_note,
      status = 'closed'
    where log.employee_id::text = p_employee_id
      and (log.id::text = p_payload->>'log_id' or log.client_action_id = p_payload->>'log_id')
      and log.status = 'open'
      and attendance_row.check_out_at >= log.check_in_at
    returning log.id::text into sender_name;
    if sender_name is null then raise exception 'تعذر العثور على دوام مفتوح مطابق أو وقت الخروج غير صالح'; end if;
    result_value := jsonb_build_object('id', sender_name, 'type', p_action_type);

    action_time := attendance_row.check_out_at;
    action_time_text := to_char(action_time at time zone 'Asia/Damascus', 'HH12:MI') ||
      case when extract(hour from action_time at time zone 'Asia/Damascus') < 12 then ' ص' else ' م' end;
    sender_name := coalesce(nullif(employee_row.display_name, ''), nullif(employee_row.full_name, ''), 'موظف');
    begin
      insert into public.ansar_notification_queue(
        employee_id, title, body, data, status, notification_key
      )
      select
        recipient.id::text,
        'تسجيل خروج دوام',
        sender_name || ' سجل الخروج الساعة ' || action_time_text ||
          case when coalesce(attendance_row.check_out_is_backdated, false) then ' (سُجل لاحقاً)' else '' end,
        jsonb_strip_nulls(jsonb_build_object(
          'type', 'attendance_check_out', 'route', 'attendance',
          'attendance_id', result_value->>'id',
          'sender_id', employee_row.id::text,
          'sender_name', sender_name,
          'sender_avatar_url', sender_avatar_url,
          'effective_at', action_time,
          'is_backdated', coalesce(attendance_row.check_out_is_backdated, false)
        )),
        'pending',
        'offline:' || p_action_id || ':' || recipient.id::text
      from public.ansar_employees recipient
      where coalesce(recipient.is_active, true) = true
        and recipient.id::text <> p_employee_id;
    exception when others then
      null;
    end;

  elsif p_action_type = 'chat_send' then
    select * into thread_row from public.ansar_chat_threads
    where id::text = p_payload->>'thread_id' and coalesce(is_active, true) = true;
    if not found then raise exception 'المحادثة غير موجودة'; end if;
    if thread_row.thread_type <> 'general' and not exists (
      select 1 from public.ansar_chat_participants participant
      where participant.thread_id::text = thread_row.id::text
        and participant.employee_id::text = p_employee_id
    ) then raise exception 'لا يمكنك الإرسال إلى هذه المحادثة'; end if;

    message_row := jsonb_populate_record(null::public.ansar_chat_messages, p_payload);
    message_row.thread_id := thread_row.id;
    message_row.sender_id := employee_row.id;
    if message_row.reply_to_id is not null then
      select chat_message.id::text into order_label
      from public.ansar_chat_messages chat_message
      where chat_message.id::text = message_row.reply_to_id::text
         or chat_message.client_action_id = message_row.reply_to_id::text
      limit 1;
      if order_label is null then raise exception 'الرسالة التي يتم الرد عليها غير موجودة'; end if;
      message_row.reply_to_id := order_label;
    end if;
    if message_row.transfer_order_id is not null then
      select transfer_order.id::text into order_label
      from public.ansar_transfer_orders transfer_order
      where transfer_order.id::text = message_row.transfer_order_id::text
         or transfer_order.client_action_id = message_row.transfer_order_id::text
      limit 1;
      if order_label is null then raise exception 'المناقلة المراد مشاركتها غير موجودة'; end if;
      message_row.transfer_order_id := order_label;
    end if;
    insert into public.ansar_chat_messages(
      thread_id, sender_id, body, message_type, attachments, reply_to_id,
      transfer_order_id, client_action_id, sync_version, updated_at
    ) values (
      message_row.thread_id, message_row.sender_id, coalesce(message_row.body, ''),
      coalesce(message_row.message_type, 'text'), coalesce(message_row.attachments, '[]'::jsonb),
      message_row.reply_to_id, message_row.transfer_order_id, p_action_id, 1, now()
    ) returning * into created_message;
    update public.ansar_chat_threads set updated_at = now() where id = thread_row.id;

    insert into public.ansar_chat_message_receipts(message_id, thread_id, employee_id, status)
    select created_message.id::text, thread_row.id::text, recipient.id::text, 'sent'
    from public.ansar_employees recipient
    where coalesce(recipient.is_active, true) = true
      and recipient.id::text <> p_employee_id
      and (
        thread_row.thread_type = 'general' or exists (
          select 1 from public.ansar_chat_participants participant
          where participant.thread_id::text = thread_row.id::text
            and participant.employee_id::text = recipient.id::text
        )
      )
    on conflict do nothing;

    insert into public.ansar_notification_queue(
      employee_id, title, body, data, status, notification_key
    )
    select
      recipient.id::text,
      'رسالة جديدة من ' || sender_name,
      coalesce(message_row.body, ''),
      jsonb_strip_nulls(jsonb_build_object(
        'type', 'chat_message', 'route', 'chat',
        'thread_id', thread_row.id::text,
        'message_id', created_message.id::text,
        'sender_id', employee_row.id::text,
        'sender_name', sender_name,
        'sender_avatar_url', employee_row.avatar_url,
        'rich_notification', 'true'
      )),
      'pending',
      'chat:' || created_message.id::text || ':' || recipient.id::text
    from public.ansar_employees recipient
    where coalesce(recipient.is_active, true) = true
      and recipient.id::text <> p_employee_id
      and (
        thread_row.thread_type = 'general' or exists (
          select 1 from public.ansar_chat_participants participant
          where participant.thread_id::text = thread_row.id::text
            and participant.employee_id::text = recipient.id::text
        )
      )
      and not exists (
        select 1 from public.ansar_chat_participants muted
        where muted.thread_id::text = thread_row.id::text
          and muted.employee_id::text = recipient.id::text
          and coalesce(muted.is_muted, false) = true
          and (muted.muted_until is null or muted.muted_until > now())
      )
    on conflict do nothing;
    result_value := jsonb_build_object('id', created_message.id::text, 'type', p_action_type);

  elsif p_action_type = 'transfer_create' then
    order_row := jsonb_populate_record(null::public.ansar_transfer_orders, p_payload->'order');
    order_row.requested_by := employee_row.id;
    insert into public.ansar_transfer_orders(
      from_branch_num, to_branch_num, requested_by, status, requester_note,
      submitted_at, client_action_id, sync_version, updated_at
    ) values (
      order_row.from_branch_num, order_row.to_branch_num, order_row.requested_by,
      coalesce(order_row.status, 'submitted'), order_row.requester_note,
      coalesce(order_row.submitted_at, now()), p_action_id, 1, now()
    ) returning * into created_order;
    for item_value in select value from jsonb_array_elements(coalesce(p_payload->'items', '[]'::jsonb))
    loop
      item_row := jsonb_populate_record(null::public.ansar_transfer_order_items, item_value);
      item_row.order_id := created_order.id;
      insert into public.ansar_transfer_order_items(
        order_id, mat_num, requested_quantity, note, item_status,
        client_action_id, sync_version, updated_at
      ) values (
        item_row.order_id, item_row.mat_num, item_row.requested_quantity,
        item_row.note, coalesce(item_row.item_status, 'requested'),
        item_row.client_action_id, 1, now()
      );
    end loop;
    select name into from_branch_name from public.ansar_branches where sto_num = created_order.from_branch_num limit 1;
    select name into to_branch_name from public.ansar_branches where sto_num = created_order.to_branch_num limit 1;
    from_branch_name := coalesce(from_branch_name, 'الفرع ' || created_order.from_branch_num::text);
    to_branch_name := coalesce(to_branch_name, 'الفرع ' || created_order.to_branch_num::text);
    order_label := coalesce(created_order.order_no::text, created_order.id::text);
    begin
      insert into public.ansar_order_events(order_id, employee_id, event_type, new_status, note)
      values (created_order.id, p_employee_id, 'created', created_order.status, 'إنشاء طلب المناقلة');
    exception when others then
      null;
    end;
    begin
      insert into public.ansar_notification_queue(
        employee_id, title, body, data, status, notification_key
      )
      select
        recipient.id::text,
        'طلب مناقلة جديد',
        sender_name || ' أنشأ مناقلة رقم ' || order_label || ' من ' || from_branch_name || ' إلى ' || to_branch_name,
        jsonb_strip_nulls(jsonb_build_object(
          'type', 'transfer_created', 'route', 'transfer',
          'order_id', created_order.id::text,
          'order_no', order_label,
          'from_branch_num', created_order.from_branch_num,
          'from_branch_name', from_branch_name,
          'to_branch_num', created_order.to_branch_num,
          'to_branch_name', to_branch_name,
          'sender_id', employee_row.id::text,
          'sender_name', sender_name,
          'sender_avatar_url', sender_avatar_url
        )),
        'pending',
        'offline:' || p_action_id || ':' || recipient.id::text
      from public.ansar_employees recipient
      where coalesce(recipient.is_active, true) = true
        and recipient.id::text <> p_employee_id;
    exception when others then
      null;
    end;
    result_value := jsonb_build_object('id', created_order.id::text, 'type', p_action_type);

  elsif p_action_type = 'transfer_status' then
    select * into order_row from public.ansar_transfer_orders transfer_order
    where transfer_order.id::text = p_payload->>'order_id'
       or transfer_order.client_action_id = p_payload->>'order_ref'
    for update;
    if not found then raise exception 'المناقلة غير موجودة'; end if;
    expected_version := nullif(p_payload->>'expected_version', '')::bigint;
    if expected_version is not null and order_row.sync_version <> expected_version then
      raise exception 'sync_conflict: تغيرت المناقلة على جهاز آخر';
    end if;
    update public.ansar_transfer_orders set
      status = p_payload->>'status', handled_by = p_employee_id, updated_at = now()
    where id = order_row.id;
    status_text := case p_payload->>'status'
      when 'submitted' then 'مطلوبة'
      when 'approved' then 'تمت الموافقة'
      when 'partially_available' then 'متوفرة جزئياً'
      when 'preparing' then 'قيد التحضير'
      when 'in_delivery' then 'قيد التوصيل'
      when 'received' then 'تم الاستلام'
      when 'rejected' then 'مرفوضة'
      when 'cancelled' then 'ملغية'
      else p_payload->>'status'
    end;
    select name into from_branch_name from public.ansar_branches where sto_num = order_row.from_branch_num limit 1;
    select name into to_branch_name from public.ansar_branches where sto_num = order_row.to_branch_num limit 1;
    from_branch_name := coalesce(from_branch_name, 'الفرع ' || order_row.from_branch_num::text);
    to_branch_name := coalesce(to_branch_name, 'الفرع ' || order_row.to_branch_num::text);
    order_label := coalesce(order_row.order_no::text, order_row.id::text);
    begin
      insert into public.ansar_order_events(order_id, employee_id, event_type, old_status, new_status, note)
      values (order_row.id, p_employee_id, 'status_changed', order_row.status, p_payload->>'status', 'تحديث حالة المناقلة');
    exception when others then
      null;
    end;
    begin
      insert into public.ansar_notification_queue(
        employee_id, title, body, data, status, notification_key
      )
      select
        recipient.id::text,
        'تحديث حالة مناقلة',
        sender_name || ' حدّث المناقلة رقم ' || order_label || ' من ' || from_branch_name || ' إلى ' || to_branch_name || ' إلى ' || status_text,
        jsonb_strip_nulls(jsonb_build_object(
          'type', 'transfer_status', 'route', 'transfer',
          'order_id', order_row.id::text,
          'order_no', order_label,
          'from_branch_num', order_row.from_branch_num,
          'from_branch_name', from_branch_name,
          'to_branch_num', order_row.to_branch_num,
          'to_branch_name', to_branch_name,
          'new_status', p_payload->>'status',
          'sender_id', employee_row.id::text,
          'sender_name', sender_name,
          'sender_avatar_url', sender_avatar_url
        )),
        'pending',
        'offline:' || p_action_id || ':' || recipient.id::text
      from public.ansar_employees recipient
      where coalesce(recipient.is_active, true) = true
        and recipient.id::text <> p_employee_id;
    exception when others then
      null;
    end;
    result_value := jsonb_build_object('id', order_row.id::text, 'type', p_action_type);

  elsif p_action_type = 'transfer_item' then
    select * into item_row from public.ansar_transfer_order_items transfer_item
    where transfer_item.id::text = p_payload->>'item_id'
       or transfer_item.client_action_id = p_payload->>'item_ref'
    for update;
    if not found then raise exception 'بند المناقلة غير موجود'; end if;
    expected_version := nullif(p_payload->>'expected_version', '')::bigint;
    if expected_version is not null and item_row.sync_version <> expected_version then
      raise exception 'sync_conflict: تغير البند على جهاز آخر';
    end if;
    update public.ansar_transfer_order_items set
      item_status = p_payload->>'item_status',
      approved_quantity = nullif(p_payload->>'approved_quantity', '')::numeric,
      updated_at = now()
    where id = item_row.id;
    select * into order_row from public.ansar_transfer_orders where id = item_row.order_id;
    select name into from_branch_name from public.ansar_branches where sto_num = order_row.from_branch_num limit 1;
    select name into to_branch_name from public.ansar_branches where sto_num = order_row.to_branch_num limit 1;
    from_branch_name := coalesce(from_branch_name, 'الفرع ' || order_row.from_branch_num::text);
    to_branch_name := coalesce(to_branch_name, 'الفرع ' || order_row.to_branch_num::text);
    order_label := coalesce(order_row.order_no::text, order_row.id::text);
    status_text := case p_payload->>'item_status'
      when 'available' then 'متوفر'
      when 'partial' then 'متوفر جزئياً'
      when 'unavailable' then 'غير متوفر'
      else coalesce(p_payload->>'item_status', 'محدّث')
    end;
    begin
      insert into public.ansar_order_events(order_id, employee_id, event_type, note)
      values (
        order_row.id, p_employee_id, 'item_changed',
        coalesce(nullif(p_payload->>'item_name', ''), 'مادة ' || item_row.mat_num::text) || ' · ' || status_text
      );
    exception when others then
      null;
    end;
    begin
      insert into public.ansar_notification_queue(
        employee_id, title, body, data, status, notification_key
      )
      select
        recipient.id::text,
        'تحديث بند مناقلة',
        sender_name || ' حدّث ' || coalesce(nullif(p_payload->>'item_name', ''), 'مادة ' || item_row.mat_num::text) ||
          ' في المناقلة رقم ' || order_label || ' من ' || from_branch_name || ' إلى ' || to_branch_name || ' إلى ' || status_text,
        jsonb_strip_nulls(jsonb_build_object(
          'type', 'transfer_item', 'route', 'transfer',
          'order_id', order_row.id::text,
          'order_no', order_label,
          'item_id', item_row.id::text,
          'item_name', coalesce(nullif(p_payload->>'item_name', ''), 'مادة ' || item_row.mat_num::text),
          'item_status', p_payload->>'item_status',
          'approved_quantity', nullif(p_payload->>'approved_quantity', '')::numeric,
          'from_branch_name', from_branch_name,
          'to_branch_name', to_branch_name,
          'sender_id', employee_row.id::text,
          'sender_name', sender_name,
          'sender_avatar_url', sender_avatar_url
        )),
        'pending',
        'offline:' || p_action_id || ':' || recipient.id::text
      from public.ansar_employees recipient
      where coalesce(recipient.is_active, true) = true
        and recipient.id::text <> p_employee_id;
    exception when others then
      null;
    end;
    result_value := jsonb_build_object('id', item_row.id::text, 'type', p_action_type);

  elsif p_action_type = 'transfer_receipt' then
    select * into order_row from public.ansar_transfer_orders transfer_order
    where transfer_order.id::text = p_payload->>'order_id'
       or transfer_order.client_action_id = p_payload->>'order_ref'
    for update;
    if not found then raise exception 'المناقلة غير موجودة'; end if;
    expected_version := nullif(p_payload->>'expected_version', '')::bigint;
    if expected_version is not null and order_row.sync_version <> expected_version then
      raise exception 'sync_conflict: تغيرت المناقلة على جهاز آخر قبل تأكيد الاستلام';
    end if;
    if order_row.status <> 'in_delivery' then raise exception 'لا يمكن تأكيد الاستلام قبل بدء التوصيل'; end if;
    if employee_row.branch_num is distinct from order_row.from_branch_num then
      raise exception 'تأكيد الاستلام متاح للفرع الطالب فقط';
    end if;
    select count(*) into item_count from public.ansar_transfer_order_items where order_id = order_row.id;
    select count(distinct transfer_item.id) into reviewed_count
    from jsonb_array_elements(coalesce(p_payload->'items', '[]'::jsonb)) payload_item(value)
    join public.ansar_transfer_order_items transfer_item
      on transfer_item.order_id = order_row.id
     and (
       transfer_item.id::text = payload_item.value->>'item_id'
       or transfer_item.client_action_id = payload_item.value->>'item_id'
     );
    if reviewed_count <> item_count
       or jsonb_array_length(coalesce(p_payload->'items', '[]'::jsonb)) <> item_count then
      raise exception 'يجب مراجعة جميع بنود المناقلة مرة واحدة دون تكرار';
    end if;
    reviewed_count := 0;
    for item_value in select value from jsonb_array_elements(coalesce(p_payload->'items', '[]'::jsonb))
    loop
      select * into item_row from public.ansar_transfer_order_items transfer_item
      where transfer_item.order_id = order_row.id
        and (
          transfer_item.id::text = item_value->>'item_id'
          or transfer_item.client_action_id = item_value->>'item_id'
        )
      for update;
      if not found then raise exception 'أحد بنود الاستلام غير موجود'; end if;
      if coalesce((item_value->>'received_quantity')::numeric, 0) < 0
         or coalesce((item_value->>'damaged_quantity')::numeric, 0) < 0
         or coalesce((item_value->>'received_quantity')::numeric, 0)
              + coalesce((item_value->>'damaged_quantity')::numeric, 0)
              > coalesce(item_row.approved_quantity, 0) then
        raise exception 'الكميات المستلمة والتالفة لا يجوز أن تتجاوز الكمية المرسلة';
      end if;
      update public.ansar_transfer_order_items set
        received_quantity = coalesce((item_value->>'received_quantity')::numeric, 0),
        damaged_quantity = coalesce((item_value->>'damaged_quantity')::numeric, 0),
        receipt_note = nullif(item_value->>'note', ''),
        received_at = now(), received_by = p_employee_id, updated_at = now()
      where id = item_row.id;
      reviewed_count := reviewed_count + 1;
      has_difference := has_difference
        or coalesce((item_value->>'damaged_quantity')::numeric, 0) > 0
        or coalesce((item_value->>'received_quantity')::numeric, 0) < coalesce(item_row.approved_quantity, 0)
        or nullif(item_value->>'note', '') is not null;
    end loop;
    if reviewed_count <> item_count then raise exception 'يجب مراجعة جميع بنود المناقلة'; end if;
    update public.ansar_transfer_orders set
      status = 'received', received_at = now(), received_by = p_employee_id,
      receipt_note = nullif(p_payload->>'note', ''),
      has_receipt_discrepancy = has_difference, updated_at = now()
    where id = order_row.id;
    select name into from_branch_name from public.ansar_branches where sto_num = order_row.from_branch_num limit 1;
    select name into to_branch_name from public.ansar_branches where sto_num = order_row.to_branch_num limit 1;
    from_branch_name := coalesce(from_branch_name, 'الفرع ' || order_row.from_branch_num::text);
    to_branch_name := coalesce(to_branch_name, 'الفرع ' || order_row.to_branch_num::text);
    order_label := coalesce(order_row.order_no::text, order_row.id::text);
    begin
      insert into public.ansar_order_events(order_id, employee_id, event_type, old_status, new_status, note)
      values (
        order_row.id, p_employee_id, 'receipt_confirmed', 'in_delivery', 'received',
        case when has_difference then 'تم الاستلام مع ملاحظات' else 'تم الاستلام كاملاً' end
      );
    exception when others then
      null;
    end;
    begin
      insert into public.ansar_notification_queue(
        employee_id, title, body, data, status, notification_key
      )
      select
        recipient.id::text,
        'تم استلام المناقلة',
        sender_name || ' أكد استلام المناقلة رقم ' || order_label || ' من ' || from_branch_name || ' إلى ' || to_branch_name ||
          case when has_difference then ' مع وجود ملاحظات' else ' كاملة دون فروقات' end,
        jsonb_strip_nulls(jsonb_build_object(
          'type', 'transfer_received', 'route', 'transfer',
          'order_id', order_row.id::text,
          'order_no', order_label,
          'from_branch_num', order_row.from_branch_num,
          'from_branch_name', from_branch_name,
          'to_branch_num', order_row.to_branch_num,
          'to_branch_name', to_branch_name,
          'has_difference', has_difference,
          'sender_id', employee_row.id::text,
          'sender_name', sender_name,
          'sender_avatar_url', sender_avatar_url
        )),
        'pending',
        'offline:' || p_action_id || ':' || recipient.id::text
      from public.ansar_employees recipient
      where coalesce(recipient.is_active, true) = true
        and recipient.id::text <> p_employee_id;
    exception when others then
      null;
    end;
    result_value := jsonb_build_object(
      'id', order_row.id::text, 'type', p_action_type,
      'has_difference', has_difference
    );
  else
    raise exception 'نوع العملية غير مدعوم: %', p_action_type;
  end if;

  update public.ansar_client_actions
  set result = result_value || jsonb_build_object('duplicate', false), completed_at = now()
  where action_id = p_action_id;
  return result_value || jsonb_build_object('duplicate', false);
end;
$$;

create or replace function public.ansar_sync_pull(
  p_employee_id text,
  p_since timestamptz default (now() - interval '30 days'),
  p_limit integer default 2000
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'attendance', coalesce((
      select jsonb_agg(row_to_json(log)) from (
        select * from public.ansar_attendance_logs
        where employee_id::text = p_employee_id and updated_at > p_since
        order by updated_at, id limit greatest(1, least(p_limit, 5000))
      ) log
    ), '[]'::jsonb),
    'transfers', coalesce((
      select jsonb_agg(row_to_json(transfer_order)) from (
        select transfer_order.* from public.ansar_transfer_orders transfer_order
        join public.ansar_employees employee on employee.id::text = p_employee_id
        where transfer_order.updated_at > p_since
          and (transfer_order.from_branch_num = employee.branch_num or transfer_order.to_branch_num = employee.branch_num)
        order by transfer_order.updated_at, transfer_order.id limit greatest(1, least(p_limit, 5000))
      ) transfer_order
    ), '[]'::jsonb),
    'messages', coalesce((
      select jsonb_agg(row_to_json(message)) from (
        select message.* from public.ansar_chat_messages message
        join public.ansar_chat_threads thread on thread.id = message.thread_id
        where message.updated_at > p_since
          and (thread.thread_type = 'general' or exists (
            select 1 from public.ansar_chat_participants participant
            where participant.thread_id = thread.id and participant.employee_id::text = p_employee_id
          ))
        order by message.updated_at, message.id limit greatest(1, least(p_limit, 5000))
      ) message
    ), '[]'::jsonb)
  );
$$;

grant select, insert, update on public.ansar_client_actions to anon, authenticated, service_role;
grant execute on function public.ansar_apply_offline_action(text, text, text, jsonb)
  to anon, authenticated, service_role;
grant execute on function public.ansar_sync_pull(text, timestamptz, integer)
  to anon, authenticated, service_role;

do $$
begin
  begin alter publication supabase_realtime add table public.ansar_attendance_logs; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ansar_chat_messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ansar_transfer_orders; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ansar_transfer_order_items; exception when duplicate_object then null; end;
end;
$$;

notify pgrst, 'reload schema';
select 'ansar offline sync upgrade installed successfully' as result;
