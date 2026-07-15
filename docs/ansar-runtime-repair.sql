-- إصلاح تشغيلي موحد للاستلام، مشاركة المناقلات، الدردشة الفورية والمرفقات.
-- إضافي وقابل لإعادة التنفيذ، ولا يحذف أو يعيد تسمية أي بيانات حالية.

create extension if not exists pgcrypto with schema extensions;

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

alter table public.ansar_chat_messages
  add column if not exists message_type text not null default 'text',
  add column if not exists deleted_at timestamptz,
  add column if not exists attachments jsonb not null default '[]'::jsonb,
  add column if not exists transfer_order_id text;

alter table public.ansar_chat_participants
  add column if not exists is_muted boolean not null default false,
  add column if not exists muted_until timestamptz,
  add column if not exists is_archived boolean not null default false,
  add column if not exists archived_at timestamptz,
  add column if not exists last_delivered_at timestamptz,
  add column if not exists last_read_at timestamptz;

alter table public.ansar_notification_queue
  add column if not exists notification_key text;

create unique index if not exists ansar_notification_queue_key_uidx
  on public.ansar_notification_queue (notification_key)
  where notification_key is not null;

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

  select branch_num into employee_branch
  from public.ansar_employees
  where id::text = p_employee_id and coalesce(is_active, true) = true;
  if not found or employee_branch is distinct from order_row.from_branch_num then
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
  if item_count = 0
     or reviewed_count <> item_count
     or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) <> item_count then
    raise exception 'يجب مراجعة جميع بنود المناقلة';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_items) payload(value)
    join public.ansar_transfer_order_items item
      on item.id::text = payload.value->>'item_id'
    where item.order_id::text = p_order_id
      and (
        coalesce((payload.value->>'received_quantity')::numeric, 0) < 0
        or coalesce((payload.value->>'damaged_quantity')::numeric, 0) < 0
        or coalesce((payload.value->>'received_quantity')::numeric, 0)
          + coalesce((payload.value->>'damaged_quantity')::numeric, 0)
          > coalesce(item.approved_quantity, 0)
      )
  ) then
    raise exception 'الكميات المستلمة والتالفة لا يجوز أن تتجاوز الكمية المرسلة';
  end if;

  update public.ansar_transfer_order_items item
  set received_quantity = coalesce((payload.value->>'received_quantity')::numeric, 0),
      damaged_quantity = coalesce((payload.value->>'damaged_quantity')::numeric, 0),
      receipt_note = nullif(payload.value->>'note', ''),
      received_at = now(),
      received_by = p_employee_id
  from jsonb_array_elements(p_items) payload(value)
  where item.order_id::text = p_order_id
    and item.id::text = payload.value->>'item_id';

  select exists (
    select 1
    from public.ansar_transfer_order_items item
    where item.order_id::text = p_order_id
      and (
        coalesce(item.damaged_quantity, 0) > 0
        or coalesce(item.received_quantity, 0) < coalesce(item.approved_quantity, 0)
        or item.receipt_note is not null
      )
  ) into has_difference;

  update public.ansar_transfer_orders
  set status = 'received',
      received_at = now(),
      received_by = p_employee_id,
      receipt_note = nullif(p_note, ''),
      has_receipt_discrepancy = has_difference
  where id::text = p_order_id;

  begin
    insert into public.ansar_order_events (
      order_id, employee_id, event_type, old_status, new_status, note
    ) values (
      order_row.id, p_employee_id, 'receipt_confirmed', 'in_delivery', 'received',
      case when has_difference then 'تم الاستلام مع ملاحظات' else 'تم الاستلام كاملاً' end
    );
  exception when others then
    null;
  end;

  return jsonb_build_object('received', true, 'has_difference', has_difference);
end;
$$;

create or replace function public.ansar_create_chat_receipts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ansar_chat_message_receipts (
    message_id, thread_id, employee_id, status, sent_at, updated_at
  )
  select new.id::text, new.thread_id::text, recipient.employee_id, 'sent', coalesce(new.created_at, now()), now()
  from (
    select employee.id::text as employee_id
    from public.ansar_employees employee
    join public.ansar_chat_threads thread on thread.id::text = new.thread_id::text
    where thread.thread_type = 'general'
      and coalesce(employee.is_active, true) = true
      and employee.id::text <> new.sender_id::text
    union
    select participant.employee_id::text
    from public.ansar_chat_participants participant
    join public.ansar_chat_threads thread on thread.id::text = new.thread_id::text
    where thread.thread_type <> 'general'
      and participant.thread_id::text = new.thread_id::text
      and participant.employee_id::text <> new.sender_id::text
  ) recipient
  on conflict (message_id, employee_id) do nothing;

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

insert into public.ansar_chat_message_receipts (
  message_id, thread_id, employee_id, status, sent_at, read_at, updated_at
)
select
  message.id::text,
  message.thread_id::text,
  recipient.employee_id,
  case when message.created_at >= now() - interval '24 hours' then 'sent' else 'read' end,
  coalesce(message.created_at, now()),
  case when message.created_at < now() - interval '24 hours' then now() else null end,
  now()
from public.ansar_chat_messages message
join lateral (
  select employee.id::text as employee_id
  from public.ansar_employees employee
  join public.ansar_chat_threads thread on thread.id::text = message.thread_id::text
  where thread.thread_type = 'general'
    and coalesce(employee.is_active, true) = true
  union
  select participant.employee_id::text
  from public.ansar_chat_participants participant
  join public.ansar_chat_threads thread on thread.id::text = message.thread_id::text
  where thread.thread_type <> 'general'
    and participant.thread_id::text = message.thread_id::text
) recipient on true
where recipient.employee_id <> message.sender_id::text
on conflict (message_id, employee_id) do nothing;

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
  where employee_id = p_employee_id and thread_id = p_thread_id and status = 'sent';
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
  where employee_id = p_employee_id and thread_id = p_thread_id and status <> 'read';
  get diagnostics changed = row_count;
  update public.ansar_chat_participants
  set last_read_at = now(), is_archived = false, archived_at = null
  where employee_id::text = p_employee_id and thread_id::text = p_thread_id;
  return changed;
end;
$$;

create or replace function public.ansar_chat_unread_counts(p_employee_id text)
returns table (thread_id text, unread_count bigint)
language sql
security definer
set search_path = public
stable
as $$
  select receipt.thread_id::text, count(*)::bigint
  from public.ansar_chat_message_receipts receipt
  where receipt.employee_id::text = p_employee_id
    and receipt.status <> 'read'
  group by receipt.thread_id::text;
$$;

create or replace function public.ansar_validate_transfer_status_transition()
returns trigger
language plpgsql
as $$
declare allowed boolean := false;
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

create or replace function public.ansar_share_transfer_to_chat(
  p_order_id text,
  p_thread_ids jsonb,
  p_sender_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  order_row record;
  thread_value text;
  thread_row record;
  message_row record;
  sender_row record;
  from_name text;
  to_name text;
  body_text text;
  message_ids jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_thread_ids) <> 'array' or jsonb_array_length(p_thread_ids) = 0 then
    raise exception 'اختر محادثة واحدة على الأقل';
  end if;

  select employee.* into sender_row
  from public.ansar_employees employee
  where employee.id::text = p_sender_id and coalesce(employee.is_active, true) = true;
  if not found then raise exception 'الموظف غير موجود أو غير نشط'; end if;

  select * into order_row
  from public.ansar_transfer_orders transfer_order
  where transfer_order.id::text = p_order_id;
  if not found then raise exception 'المناقلة غير موجودة'; end if;

  select branch.name into from_name from public.ansar_branches branch
  where branch.sto_num = order_row.from_branch_num limit 1;
  select branch.name into to_name from public.ansar_branches branch
  where branch.sto_num = order_row.to_branch_num limit 1;
  body_text := format(
    'مناقلة رقم %s · من %s إلى %s',
    coalesce(order_row.order_no::text, '-'),
    coalesce(from_name, order_row.from_branch_num::text),
    coalesce(to_name, order_row.to_branch_num::text)
  );

  for thread_value in select jsonb_array_elements_text(p_thread_ids)
  loop
    select * into thread_row
    from public.ansar_chat_threads thread
    where thread.id::text = thread_value and coalesce(thread.is_active, true) = true;
    if not found then raise exception 'إحدى المحادثات المختارة غير موجودة'; end if;
    if thread_row.thread_type <> 'general' and not exists (
      select 1 from public.ansar_chat_participants participant
      where participant.thread_id::text = thread_value
        and participant.employee_id::text = p_sender_id
    ) then
      raise exception 'لا يمكن المشاركة في محادثة لست عضواً فيها';
    end if;

    insert into public.ansar_chat_messages (
      thread_id, sender_id, body, message_type, transfer_order_id
    ) values (
      thread_row.id, sender_row.id, body_text, 'transfer', p_order_id
    ) returning * into message_row;

    update public.ansar_chat_threads set updated_at = now() where id = thread_row.id;

    insert into public.ansar_notification_queue (
      employee_id, title, body, data, status, notification_key
    )
    select
      recipient.id::text,
      'مناقلة شاركها ' || coalesce(nullif(sender_row.display_name, ''), nullif(sender_row.full_name, ''), 'موظف'),
      body_text,
      jsonb_strip_nulls(jsonb_build_object(
        'type', 'chat_transfer',
        'route', 'chat',
        'thread_id', thread_row.id::text,
        'message_id', message_row.id::text,
        'transfer_order_id', order_row.id::text,
        'sender_id', sender_row.id::text,
        'sender_name', coalesce(nullif(sender_row.display_name, ''), nullif(sender_row.full_name, ''), 'موظف'),
        'sender_avatar_url', nullif(sender_row.avatar_url, ''),
        'message_preview', body_text,
        'thread_title', nullif(thread_row.title, ''),
        'thread_type', thread_row.thread_type
      )),
      'pending',
      'chat:' || message_row.id::text || ':' || recipient.id::text
    from public.ansar_employees recipient
    where coalesce(recipient.is_active, true) = true
      and recipient.id::text <> p_sender_id
      and (
        thread_row.thread_type = 'general'
        or exists (
          select 1 from public.ansar_chat_participants membership
          where membership.thread_id::text = thread_row.id::text
            and membership.employee_id::text = recipient.id::text
        )
      )
    on conflict do nothing;

    message_ids := message_ids || jsonb_build_array(message_row.id::text);
  end loop;

  return jsonb_build_object('message_ids', message_ids, 'count', jsonb_array_length(message_ids));
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit)
values ('ansar-chat', 'ansar-chat', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists "ansar chat attachments read" on storage.objects;
create policy "ansar chat attachments read" on storage.objects
for select to anon, authenticated using (bucket_id = 'ansar-chat');
drop policy if exists "ansar chat attachments upload" on storage.objects;
create policy "ansar chat attachments upload" on storage.objects
for insert to anon, authenticated with check (bucket_id = 'ansar-chat');
drop policy if exists "ansar chat attachments delete" on storage.objects;
create policy "ansar chat attachments delete" on storage.objects
for delete to anon, authenticated using (bucket_id = 'ansar-chat');

alter table public.ansar_transfer_orders replica identity full;
alter table public.ansar_transfer_order_items replica identity full;
alter table public.ansar_chat_messages replica identity full;
alter table public.ansar_chat_message_receipts replica identity full;
alter table public.ansar_chat_threads replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.ansar_transfer_orders;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ansar_transfer_order_items;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_messages;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_message_receipts;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_threads;
exception when duplicate_object then null; end $$;

grant select, insert, update, delete on public.ansar_chat_message_receipts
  to anon, authenticated, service_role;
grant execute on function public.ansar_confirm_transfer_receipt(text, text, jsonb, text)
  to anon, authenticated, service_role;
grant execute on function public.ansar_chat_unread_counts(text)
  to anon, authenticated, service_role;
grant execute on function public.ansar_mark_chat_delivered(text, text)
  to anon, authenticated, service_role;
grant execute on function public.ansar_mark_chat_read(text, text)
  to anon, authenticated, service_role;
grant execute on function public.ansar_share_transfer_to_chat(text, jsonb, text)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';

select 'ansar runtime repair installed successfully' as result;
