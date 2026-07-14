-- إصلاحات الدردشة الفورية والإشعارات الغنية والمشاركة وملف الموظف العام.
-- هذا الترحيل إضافي وقابل لإعادة التنفيذ، ولا يحذف أو يعيد تسمية أي بيانات قائمة.

create extension if not exists pgcrypto with schema extensions;

alter table public.ansar_device_installations
  add column if not exists notification_capabilities jsonb not null default '{}'::jsonb;

alter table public.ansar_chat_messages
  add column if not exists source_notification_id text;

create unique index if not exists ansar_chat_message_notification_reply_uidx
  on public.ansar_chat_messages (sender_id, source_notification_id)
  where source_notification_id is not null;

-- إصلاح إيصالات الرسائل القديمة والجديدة.
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
  select
    new.id::text,
    new.thread_id::text,
    recipient.employee_id::text,
    'sent',
    coalesce(new.created_at, now()),
    now()
  from (
    select participant.employee_id::text as employee_id
    from public.ansar_chat_participants participant
    where participant.thread_id::text = new.thread_id::text
    union
    select employee.id::text
    from public.ansar_employees employee
    join public.ansar_chat_threads thread on thread.id::text = new.thread_id::text
    where thread.thread_type = 'general'
      and coalesce(employee.is_active, true) = true
  ) recipient
  where recipient.employee_id::text <> new.sender_id::text
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
  message_id, thread_id, employee_id, status, sent_at, updated_at
)
select
  message.id::text,
  message.thread_id::text,
  recipient.employee_id::text,
  'sent',
  coalesce(message.created_at, now()),
  now()
from public.ansar_chat_messages message
join lateral (
  select participant.employee_id::text as employee_id
  from public.ansar_chat_participants participant
  where participant.thread_id::text = message.thread_id::text
  union
  select employee.id::text
  from public.ansar_employees employee
  join public.ansar_chat_threads thread on thread.id::text = message.thread_id::text
  where thread.thread_type = 'general'
    and thread.id::text = message.thread_id::text
    and coalesce(employee.is_active, true) = true
) recipient on true
where recipient.employee_id::text <> message.sender_id::text
on conflict (message_id, employee_id) do nothing;

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
    and not exists (
      select 1
      from public.ansar_chat_message_hidden hidden
      where hidden.employee_id::text = p_employee_id
        and hidden.message_id::text = receipt.message_id::text
    )
  group by receipt.thread_id::text;
$$;

create or replace function public.ansar_send_chat_reply(
  p_installation_id text,
  p_thread_id text,
  p_body text,
  p_notification_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  employee_id text;
  employee_row record;
  thread_row record;
  existing_id text;
  inserted_row record;
begin
  if nullif(btrim(p_body), '') is null then
    raise exception 'لا يمكن إرسال رد فارغ';
  end if;
  if char_length(btrim(p_body)) > 4000 then
    raise exception 'الرد أطول من الحد المسموح';
  end if;

  select employee.*, installation.employee_id::text as resolved_employee_id
  into employee_row
  from public.ansar_device_installations installation
  join public.ansar_employees employee
    on employee.id::text = installation.employee_id::text
  where installation.installation_id = p_installation_id
    and installation.is_active = true
    and coalesce(employee.is_active, true) = true
  order by installation.last_seen_at desc
  limit 1;

  if not found then
    raise exception 'هذا الجهاز غير مسجل للإشعارات';
  end if;
  employee_id := employee_row.resolved_employee_id;

  select thread.*
  into thread_row
  from public.ansar_chat_threads thread
  where thread.id::text = p_thread_id
    and coalesce(thread.is_active, true) = true;

  if not found then
    raise exception 'المحادثة غير موجودة';
  end if;
  if thread_row.thread_type <> 'general' and not exists (
    select 1
    from public.ansar_chat_participants participant
    where participant.thread_id::text = p_thread_id
      and participant.employee_id::text = employee_id
  ) then
    raise exception 'الموظف ليس عضواً في هذه المحادثة';
  end if;

  select message.id::text
  into existing_id
  from public.ansar_chat_messages message
  where message.sender_id::text = employee_id
    and message.source_notification_id = p_notification_id
  limit 1;

  if existing_id is not null then
    return jsonb_build_object('message_id', existing_id, 'duplicate', true);
  end if;

  insert into public.ansar_chat_messages (
    thread_id, sender_id, body, message_type, source_notification_id
  ) values (
    thread_row.id, employee_row.id, btrim(p_body), 'text', nullif(p_notification_id, '')
  )
  returning * into inserted_row;

  update public.ansar_chat_threads
  set updated_at = now()
  where id = thread_row.id;

  insert into public.ansar_notification_queue (
    employee_id, title, body, data, status, notification_key
  )
  select
    recipient.id::text,
    case
      when thread_row.thread_type = 'general' then
        coalesce(
          nullif(employee_row.display_name, ''),
          nullif(employee_row.full_name, ''),
          'موظف'
        ) || ' في الدردشة العامة'
      else
        'رسالة جديدة من ' || coalesce(
          nullif(employee_row.display_name, ''),
          nullif(employee_row.full_name, ''),
          'موظف'
        )
    end,
    btrim(p_body),
    jsonb_strip_nulls(jsonb_build_object(
      'type', 'chat_message',
      'route', 'chat',
      'thread_id', thread_row.id::text,
      'message_id', inserted_row.id::text,
      'sender_id', employee_row.id::text,
      'sender_name', coalesce(
        nullif(employee_row.display_name, ''),
        nullif(employee_row.full_name, ''),
        'موظف'
      ),
      'sender_avatar_url', nullif(employee_row.avatar_url, ''),
      'message_preview', btrim(p_body),
      'thread_title', nullif(thread_row.title, ''),
      'thread_type', thread_row.thread_type
    )),
    'pending',
    'chat:' || inserted_row.id::text || ':' || recipient.id::text
  from public.ansar_employees recipient
  where coalesce(recipient.is_active, true) = true
    and recipient.id::text <> employee_id
    and (
      thread_row.thread_type = 'general'
      or exists (
        select 1
        from public.ansar_chat_participants membership
        where membership.thread_id::text = thread_row.id::text
          and membership.employee_id::text = recipient.id::text
      )
    )
    and not exists (
      select 1
      from public.ansar_chat_participants muted
      where muted.thread_id::text = thread_row.id::text
        and muted.employee_id::text = recipient.id::text
        and muted.is_muted = true
        and (muted.muted_until is null or muted.muted_until > now())
    )
  on conflict do nothing;

  return jsonb_build_object('message_id', inserted_row.id::text, 'duplicate', false);
exception
  when unique_violation then
    select message.id::text
    into existing_id
    from public.ansar_chat_messages message
    where message.sender_id::text = employee_id
      and message.source_notification_id = p_notification_id
    limit 1;
    return jsonb_build_object('message_id', existing_id, 'duplicate', true);
end;
$$;

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
  where employee.id::text = p_sender_id
    and coalesce(employee.is_active, true) = true;
  if not found then
    raise exception 'الموظف غير موجود أو غير نشط';
  end if;

  select * into order_row
  from public.ansar_transfer_orders transfer_order
  where transfer_order.id::text = p_order_id;
  if not found then raise exception 'المناقلة غير موجودة'; end if;

  select branch.name into from_name
  from public.ansar_branches branch
  where branch.sto_num = order_row.from_branch_num
  limit 1;
  select branch.name into to_name
  from public.ansar_branches branch
  where branch.sto_num = order_row.to_branch_num
  limit 1;

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
    where thread.id::text = thread_value
      and coalesce(thread.is_active, true) = true;
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

    update public.ansar_chat_threads
    set updated_at = now()
    where id = thread_row.id;

    insert into public.ansar_notification_queue (
      employee_id, title, body, data, status, notification_key
    )
    select
      recipient.id::text,
      'مناقلة شاركها ' || coalesce(
        nullif(sender_row.display_name, ''),
        nullif(sender_row.full_name, ''),
        'موظف'
      ),
      body_text,
      jsonb_strip_nulls(jsonb_build_object(
        'type', 'chat_transfer',
        'route', 'chat',
        'thread_id', thread_row.id::text,
        'message_id', message_row.id::text,
        'transfer_order_id', order_row.id::text,
        'order_no', order_row.order_no::text,
        'from_branch_name', coalesce(from_name, order_row.from_branch_num::text),
        'to_branch_name', coalesce(to_name, order_row.to_branch_num::text),
        'transfer_status', order_row.status,
        'sender_id', sender_row.id::text,
        'sender_name', coalesce(
          nullif(sender_row.display_name, ''),
          nullif(sender_row.full_name, ''),
          'موظف'
        ),
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
          select 1
          from public.ansar_chat_participants membership
          where membership.thread_id::text = thread_row.id::text
            and membership.employee_id::text = recipient.id::text
        )
      )
      and not exists (
        select 1
        from public.ansar_chat_participants muted
        where muted.thread_id::text = thread_row.id::text
          and muted.employee_id::text = recipient.id::text
          and muted.is_muted = true
          and (muted.muted_until is null or muted.muted_until > now())
      )
    on conflict do nothing;

    message_ids := message_ids || jsonb_build_array(message_row.id::text);
  end loop;

  return jsonb_build_object('message_ids', message_ids, 'count', jsonb_array_length(message_ids));
end;
$$;

create or replace function public.ansar_employee_public_profile(p_employee_id text)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', employee.id::text,
    'display_name', employee.display_name,
    'full_name', employee.full_name,
    'avatar_url', employee.avatar_url,
    'phone', employee.phone,
    'email', employee.email,
    'job_title', employee.job_title,
    'branch_num', employee.branch_num,
    'branch_name', branch.name,
    'role', employee.role,
    'last_seen_at', employee.last_seen_at
  ))
  from public.ansar_employees employee
  left join public.ansar_branches branch on branch.sto_num = employee.branch_num
  where employee.id::text = p_employee_id
    and coalesce(employee.is_active, true) = true
  limit 1;
$$;

-- مساحة المرفقات تبقى خاصة، والتطبيق يحصل على روابط عرض مؤقتة.
insert into storage.buckets (id, name, public, file_size_limit)
values ('ansar-chat', 'ansar-chat', false, 10485760)
on conflict (id) do update
set public = false, file_size_limit = 10485760;

drop policy if exists "ansar chat attachments read" on storage.objects;
create policy "ansar chat attachments read"
on storage.objects for select to anon, authenticated
using (bucket_id = 'ansar-chat');

drop policy if exists "ansar chat attachments upload" on storage.objects;
create policy "ansar chat attachments upload"
on storage.objects for insert to anon, authenticated
with check (bucket_id = 'ansar-chat');

drop policy if exists "ansar chat attachments update" on storage.objects;
create policy "ansar chat attachments update"
on storage.objects for update to anon, authenticated
using (bucket_id = 'ansar-chat')
with check (bucket_id = 'ansar-chat');

drop policy if exists "ansar chat attachments delete" on storage.objects;
create policy "ansar chat attachments delete"
on storage.objects for delete to anon, authenticated
using (bucket_id = 'ansar-chat');

alter table public.ansar_chat_messages replica identity full;
alter table public.ansar_chat_message_receipts replica identity full;
alter table public.ansar_chat_threads replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_messages;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_message_receipts;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.ansar_chat_threads;
exception when duplicate_object then null; end $$;

grant select, insert, update, delete on public.ansar_chat_message_receipts to anon, authenticated, service_role;
grant execute on function public.ansar_chat_unread_counts(text) to anon, authenticated, service_role;
grant execute on function public.ansar_send_chat_reply(text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_share_transfer_to_chat(text, jsonb, text) to anon, authenticated, service_role;
grant execute on function public.ansar_employee_public_profile(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
