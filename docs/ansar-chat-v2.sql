-- فريق الأنصار: ترقية الدردشة الثانية.
-- ترحيل إضافي قابل لإعادة التنفيذ. لا يحذف ولا يعيد تسمية أي بيانات قائمة.

create extension if not exists pgcrypto with schema extensions;

insert into storage.buckets (id, name, public, file_size_limit)
values ('ansar-chat', 'ansar-chat', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;

alter table public.ansar_chat_threads
  add column if not exists channel_kind text not null default 'conversation',
  add column if not exists branch_num integer,
  add column if not exists posting_policy text not null default 'members',
  add column if not exists system_key text;

alter table public.ansar_chat_participants
  add column if not exists notification_mode text not null default 'all',
  add column if not exists mentions_override boolean not null default true;

alter table public.ansar_chat_messages
  add column if not exists client_message_id text,
  add column if not exists mentions jsonb not null default '[]'::jsonb,
  add column if not exists requires_ack boolean not null default false,
  add column if not exists poll_id text;

create unique index if not exists ansar_chat_threads_system_key_uidx
  on public.ansar_chat_threads (system_key)
  where system_key is not null;

create unique index if not exists ansar_chat_messages_client_uidx
  on public.ansar_chat_messages (sender_id, client_message_id)
  where client_message_id is not null;

create index if not exists ansar_chat_messages_page_idx
  on public.ansar_chat_messages (thread_id, created_at desc, id);

create table if not exists public.ansar_chat_inbox_events (
  id bigserial primary key,
  employee_id text not null,
  thread_id text not null,
  message_id text,
  event_type text not null default 'message',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists ansar_chat_inbox_events_employee_idx
  on public.ansar_chat_inbox_events (employee_id, id desc);

create table if not exists public.ansar_chat_message_reactions (
  message_id text not null,
  employee_id text not null,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, employee_id)
);

create index if not exists ansar_chat_reactions_message_idx
  on public.ansar_chat_message_reactions (message_id, created_at);

create table if not exists public.ansar_chat_starred_messages (
  employee_id text not null,
  message_id text not null,
  thread_id text not null,
  created_at timestamptz not null default now(),
  primary key (employee_id, message_id)
);

create table if not exists public.ansar_chat_pinned_messages (
  thread_id text not null,
  message_id text not null,
  pinned_by text not null,
  pinned_at timestamptz not null default now(),
  primary key (thread_id, message_id)
);

create table if not exists public.ansar_chat_polls (
  id text primary key default extensions.gen_random_uuid()::text,
  thread_id text not null,
  message_id text,
  question text not null,
  allows_multiple boolean not null default false,
  created_by text not null,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by text
);

create table if not exists public.ansar_chat_poll_options (
  id text primary key default extensions.gen_random_uuid()::text,
  poll_id text not null,
  option_text text not null,
  position integer not null default 0
);

create index if not exists ansar_chat_poll_options_poll_idx
  on public.ansar_chat_poll_options (poll_id, position);

create table if not exists public.ansar_chat_poll_votes (
  poll_id text not null,
  option_id text not null,
  employee_id text not null,
  created_at timestamptz not null default now(),
  primary key (poll_id, option_id, employee_id)
);

create table if not exists public.ansar_chat_announcement_acknowledgements (
  message_id text not null,
  employee_id text not null,
  acknowledged_at timestamptz not null default now(),
  primary key (message_id, employee_id)
);

-- يحافظ هذا الحدث الصغير على تحديث قائمة المحادثات دون مراقبة جميع الجداول.
create or replace function public.ansar_chat_v2_emit_inbox_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ansar_chat_inbox_events (
    employee_id, thread_id, message_id, event_type, payload
  )
  select
    recipient.employee_id,
    new.thread_id::text,
    new.id::text,
    'message',
    jsonb_build_object(
      'sender_id', new.sender_id::text,
      'message_type', coalesce(new.message_type, 'text'),
      'created_at', coalesce(new.created_at, now())
    )
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
  ) recipient;
  return new;
end;
$$;

drop trigger if exists ansar_chat_v2_emit_inbox_events_trigger on public.ansar_chat_messages;
create trigger ansar_chat_v2_emit_inbox_events_trigger
after insert on public.ansar_chat_messages
for each row execute function public.ansar_chat_v2_emit_inbox_events();

create or replace function public.ansar_chat_v2_emit_message_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare thread_value text; message_value text;
begin
  thread_value := coalesce(new.thread_id::text, old.thread_id::text);
  message_value := coalesce(new.id::text, old.id::text);
  insert into public.ansar_chat_inbox_events (employee_id, thread_id, message_id, event_type, payload)
  select recipient.employee_id, thread_value, message_value, 'message_changed',
    jsonb_build_object('operation', tg_op)
  from (
    select participant.employee_id::text as employee_id
    from public.ansar_chat_participants participant
    where participant.thread_id::text = thread_value
    union
    select employee.id::text
    from public.ansar_employees employee
    join public.ansar_chat_threads thread on thread.id::text = thread_value
    where thread.thread_type = 'general' and coalesce(employee.is_active, true) = true
  ) recipient;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists ansar_chat_v2_emit_message_change_trigger on public.ansar_chat_messages;
create trigger ansar_chat_v2_emit_message_change_trigger
after update or delete on public.ansar_chat_messages
for each row execute function public.ansar_chat_v2_emit_message_change();

create or replace function public.ansar_chat_v2_emit_related_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare message_value text; thread_value text; poll_value text;
begin
  if tg_table_name = 'ansar_chat_poll_votes' then
    poll_value := coalesce(new.poll_id, old.poll_id);
    select poll.message_id, poll.thread_id into message_value, thread_value
    from public.ansar_chat_polls poll where poll.id = poll_value;
  elsif tg_table_name = 'ansar_chat_polls' then
    message_value := coalesce(new.message_id, old.message_id);
    thread_value := coalesce(new.thread_id, old.thread_id);
  else
    message_value := coalesce(new.message_id, old.message_id);
    select message.thread_id::text into thread_value
    from public.ansar_chat_messages message where message.id::text = message_value;
  end if;
  if thread_value is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  insert into public.ansar_chat_inbox_events (employee_id, thread_id, message_id, event_type, payload)
  select recipient.employee_id, thread_value, message_value, 'message_state_changed',
    jsonb_build_object('source', tg_table_name, 'operation', tg_op)
  from (
    select participant.employee_id::text as employee_id
    from public.ansar_chat_participants participant
    where participant.thread_id::text = thread_value
    union
    select employee.id::text
    from public.ansar_employees employee
    join public.ansar_chat_threads thread on thread.id::text = thread_value
    where thread.thread_type = 'general' and coalesce(employee.is_active, true) = true
  ) recipient;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists ansar_chat_v2_reaction_change_trigger on public.ansar_chat_message_reactions;
create trigger ansar_chat_v2_reaction_change_trigger
after insert or update or delete on public.ansar_chat_message_reactions
for each row execute function public.ansar_chat_v2_emit_related_change();

drop trigger if exists ansar_chat_v2_pin_change_trigger on public.ansar_chat_pinned_messages;
create trigger ansar_chat_v2_pin_change_trigger
after insert or update or delete on public.ansar_chat_pinned_messages
for each row execute function public.ansar_chat_v2_emit_related_change();

drop trigger if exists ansar_chat_v2_vote_change_trigger on public.ansar_chat_poll_votes;
create trigger ansar_chat_v2_vote_change_trigger
after insert or update or delete on public.ansar_chat_poll_votes
for each row execute function public.ansar_chat_v2_emit_related_change();

drop trigger if exists ansar_chat_v2_poll_change_trigger on public.ansar_chat_polls;
create trigger ansar_chat_v2_poll_change_trigger
after update on public.ansar_chat_polls
for each row execute function public.ansar_chat_v2_emit_related_change();

drop trigger if exists ansar_chat_v2_ack_change_trigger on public.ansar_chat_announcement_acknowledgements;
create trigger ansar_chat_v2_ack_change_trigger
after insert or update or delete on public.ansar_chat_announcement_acknowledgements
for each row execute function public.ansar_chat_v2_emit_related_change();

create or replace function public.ansar_chat_is_member(p_employee_id text, p_thread_id text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.ansar_chat_threads thread
    where thread.id::text = p_thread_id
      and coalesce(thread.is_active, true) = true
      and (
        thread.thread_type = 'general'
        or exists (
          select 1
          from public.ansar_chat_participants participant
          where participant.thread_id::text = p_thread_id
            and participant.employee_id::text = p_employee_id
        )
      )
  );
$$;

create or replace function public.ansar_chat_can_manage(p_employee_id text, p_thread_id text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.ansar_employees employee
    where employee.id::text = p_employee_id
      and coalesce(employee.is_active, true) = true
      and (employee.role = 'admin' or coalesce(employee.can_manage_all_branches, false))
  ) or exists (
    select 1
    from public.ansar_chat_participants participant
    where participant.thread_id::text = p_thread_id
      and participant.employee_id::text = p_employee_id
      and participant.role = 'admin'
  );
$$;

create or replace function public.ansar_send_chat_message_v2(
  p_employee_id text,
  p_thread_id text,
  p_client_message_id text,
  p_body text default '',
  p_message_type text default 'text',
  p_attachments jsonb default '[]'::jsonb,
  p_reply_to_id text default null,
  p_mentions jsonb default '[]'::jsonb,
  p_requires_ack boolean default false,
  p_forwarded_from_id text default null,
  p_poll jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  employee_row record;
  thread_row record;
  message_row record;
  existing_row record;
  poll_row record;
  option_value text;
  mentioned boolean;
begin
  if nullif(btrim(p_client_message_id), '') is null then
    raise exception 'معرف الرسالة المحلي مطلوب';
  end if;
  if char_length(coalesce(p_body, '')) > 4000 then
    raise exception 'الرسالة أطول من الحد المسموح';
  end if;
  if jsonb_typeof(coalesce(p_attachments, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 5 then
    raise exception 'عدد المرفقات غير صالح';
  end if;

  select * into employee_row
  from public.ansar_employees employee
  where employee.id::text = p_employee_id
    and coalesce(employee.is_active, true) = true;
  if not found then raise exception 'الموظف غير موجود أو غير نشط'; end if;

  select * into thread_row
  from public.ansar_chat_threads thread
  where thread.id::text = p_thread_id
    and coalesce(thread.is_active, true) = true;
  if not found then raise exception 'المحادثة غير موجودة'; end if;
  if not public.ansar_chat_is_member(p_employee_id, p_thread_id) then
    raise exception 'الموظف ليس عضواً في هذه المحادثة';
  end if;
  if thread_row.posting_policy = 'admins'
     and not public.ansar_chat_can_manage(p_employee_id, p_thread_id) then
    raise exception 'النشر في هذه القناة متاح للإدارة فقط';
  end if;

  select * into existing_row
  from public.ansar_chat_messages message
  where message.sender_id::text = p_employee_id
    and message.client_message_id = p_client_message_id
  limit 1;
  if found then
    return jsonb_build_object('message', to_jsonb(existing_row), 'duplicate', true);
  end if;

  if p_message_type = 'poll' then
    if p_poll is null or nullif(btrim(p_poll->>'question'), '') is null then
      raise exception 'سؤال الاستبيان مطلوب';
    end if;
    insert into public.ansar_chat_polls (
      thread_id, question, allows_multiple, created_by
    ) values (
      p_thread_id,
      btrim(p_poll->>'question'),
      coalesce((p_poll->>'allows_multiple')::boolean, false),
      p_employee_id
    ) returning * into poll_row;

    for option_value in
      select btrim(value)
      from jsonb_array_elements_text(coalesce(p_poll->'options', '[]'::jsonb))
      where nullif(btrim(value), '') is not null
    loop
      insert into public.ansar_chat_poll_options (poll_id, option_text, position)
      values (
        poll_row.id,
        option_value,
        (select count(*) from public.ansar_chat_poll_options option_row where option_row.poll_id = poll_row.id)
      );
    end loop;
    if (select count(*) from public.ansar_chat_poll_options option_row where option_row.poll_id = poll_row.id) < 2 then
      raise exception 'أضف خيارين على الأقل للاستبيان';
    end if;
  end if;

  insert into public.ansar_chat_messages (
    thread_id, sender_id, body, message_type, attachments, reply_to_id, forwarded_from_id,
    client_message_id, mentions, requires_ack, poll_id
  ) values (
    thread_row.id,
    employee_row.id,
    btrim(coalesce(p_body, '')),
    p_message_type,
    coalesce(p_attachments, '[]'::jsonb),
    nullif(p_reply_to_id, ''),
    nullif(p_forwarded_from_id, ''),
    p_client_message_id,
    coalesce(p_mentions, '[]'::jsonb),
    coalesce(p_requires_ack, false),
    poll_row.id
  ) returning * into message_row;

  if poll_row.id is not null then
    update public.ansar_chat_polls set message_id = message_row.id::text where id = poll_row.id;
  end if;
  update public.ansar_chat_threads set updated_at = now() where id = thread_row.id;

  insert into public.ansar_notification_queue (
    employee_id, title, body, data, status, notification_key
  )
  select
    recipient.id::text,
    case
      when thread_row.channel_kind = 'announcement' then 'إعلان رسمي'
      when thread_row.thread_type = 'direct' then 'رسالة من ' || coalesce(employee_row.display_name, employee_row.full_name, 'موظف')
      else coalesce(thread_row.title, 'رسالة جديدة')
    end,
    case
      when p_message_type = 'voice' then 'رسالة صوتية'
      when p_message_type = 'poll' then 'استبيان: ' || coalesce(p_poll->>'question', '')
      when nullif(btrim(coalesce(p_body, '')), '') is null then 'مرفق جديد'
      else left(btrim(p_body), 180)
    end,
    jsonb_strip_nulls(jsonb_build_object(
      'type', case when thread_row.channel_kind = 'announcement' then 'chat_announcement' else 'chat_message' end,
      'route', 'chat',
      'thread_id', thread_row.id::text,
      'message_id', message_row.id::text,
      'sender_id', employee_row.id::text,
      'sender_name', coalesce(employee_row.display_name, employee_row.full_name, 'موظف'),
      'sender_avatar_url', nullif(employee_row.avatar_url, ''),
      'thread_title', nullif(thread_row.title, ''),
      'thread_type', thread_row.thread_type,
      'channel_kind', thread_row.channel_kind,
      'message_preview', left(coalesce(p_body, ''), 180),
      'requires_ack', coalesce(p_requires_ack, false)
    )),
    'pending',
    'chat-v2:' || message_row.id::text || ':' || recipient.id::text
  from public.ansar_employees recipient
  where coalesce(recipient.is_active, true) = true
    and recipient.id::text <> p_employee_id
    and public.ansar_chat_is_member(recipient.id::text, p_thread_id)
    and (
      thread_row.channel_kind = 'announcement'
      or exists (
        select 1 from jsonb_array_elements_text(coalesce(p_mentions, '[]'::jsonb)) mention
        where mention = recipient.id::text
      )
      or not exists (
        select 1
        from public.ansar_chat_participants muted
        where muted.thread_id::text = p_thread_id
          and muted.employee_id::text = recipient.id::text
          and muted.is_muted = true
          and (muted.muted_until is null or muted.muted_until > now())
      )
    )
  on conflict do nothing;

  return jsonb_build_object('message', to_jsonb(message_row), 'duplicate', false);
exception
  when unique_violation then
    select * into existing_row
    from public.ansar_chat_messages message
    where message.sender_id::text = p_employee_id
      and message.client_message_id = p_client_message_id
    limit 1;
    return jsonb_build_object('message', to_jsonb(existing_row), 'duplicate', true);
end;
$$;

-- الرد من إشعار Android يمر بمسار الإرسال نفسه ويحترم سياسة القنوات.
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
declare employee_value text; send_result jsonb; message_value text;
begin
  select installation.employee_id::text into employee_value
  from public.ansar_device_installations installation
  join public.ansar_employees employee on employee.id::text = installation.employee_id::text
  where installation.installation_id = p_installation_id
    and installation.is_active = true
    and coalesce(employee.is_active, true) = true
  order by installation.last_seen_at desc
  limit 1;
  if employee_value is null then raise exception 'هذا الجهاز غير مسجل للإشعارات'; end if;
  send_result := public.ansar_send_chat_message_v2(
    employee_value,
    p_thread_id,
    'notification-reply:' || coalesce(nullif(p_notification_id, ''), extensions.gen_random_uuid()::text),
    p_body,
    'text',
    '[]'::jsonb,
    null,
    '[]'::jsonb,
    false,
    null,
    null
  );
  message_value := send_result->'message'->>'id';
  if message_value is not null and nullif(p_notification_id, '') is not null then
    update public.ansar_chat_messages
    set source_notification_id = p_notification_id
    where id::text = message_value and source_notification_id is null;
  end if;
  return jsonb_build_object(
    'message_id', message_value,
    'duplicate', coalesce((send_result->>'duplicate')::boolean, false)
  );
end;
$$;

create or replace function public.ansar_edit_chat_message_v2(
  p_employee_id text, p_message_id text, p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare message_row record;
begin
  select * into message_row from public.ansar_chat_messages message
  where message.id::text = p_message_id for update;
  if not found then raise exception 'الرسالة غير موجودة'; end if;
  if message_row.sender_id::text <> p_employee_id then raise exception 'يمكنك تعديل رسائلك فقط'; end if;
  if message_row.created_at < now() - interval '24 hours' then raise exception 'انتهت مهلة تعديل الرسالة'; end if;
  if message_row.deleted_at is not null then raise exception 'الرسالة محذوفة'; end if;
  if nullif(btrim(p_body), '') is null then raise exception 'لا يمكن حفظ رسالة فارغة'; end if;
  update public.ansar_chat_messages
  set body = btrim(p_body), edited_at = now(), edited_by = p_employee_id
  where id = message_row.id returning * into message_row;
  return to_jsonb(message_row);
end;
$$;

create or replace function public.ansar_delete_chat_message_v2(
  p_employee_id text, p_message_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare message_row record;
begin
  select * into message_row from public.ansar_chat_messages message
  where message.id::text = p_message_id for update;
  if not found then raise exception 'الرسالة غير موجودة'; end if;
  if message_row.sender_id::text <> p_employee_id then raise exception 'يمكنك حذف رسائلك فقط'; end if;
  if message_row.created_at < now() - interval '24 hours' then raise exception 'انتهت مهلة حذف الرسالة'; end if;
  update public.ansar_chat_messages
  set body = '', attachments = '[]'::jsonb, deleted_at = now(), deleted_by = p_employee_id
  where id = message_row.id returning * into message_row;
  return to_jsonb(message_row);
end;
$$;

create or replace function public.ansar_set_chat_reaction(
  p_employee_id text, p_message_id text, p_emoji text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare thread_value text;
begin
  select message.thread_id::text into thread_value
  from public.ansar_chat_messages message where message.id::text = p_message_id;
  if not public.ansar_chat_is_member(p_employee_id, thread_value) then raise exception 'غير مصرح'; end if;
  if nullif(p_emoji, '') is null then
    delete from public.ansar_chat_message_reactions
    where message_id = p_message_id and employee_id = p_employee_id;
  else
    insert into public.ansar_chat_message_reactions (message_id, employee_id, emoji)
    values (p_message_id, p_employee_id, left(p_emoji, 16))
    on conflict (message_id, employee_id) do update set emoji = excluded.emoji, created_at = now();
  end if;
end;
$$;

create or replace function public.ansar_toggle_chat_star(
  p_employee_id text, p_message_id text, p_starred boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare thread_value text;
begin
  select message.thread_id::text into thread_value
  from public.ansar_chat_messages message where message.id::text = p_message_id;
  if not public.ansar_chat_is_member(p_employee_id, thread_value) then raise exception 'غير مصرح'; end if;
  if p_starred then
    insert into public.ansar_chat_starred_messages (employee_id, message_id, thread_id)
    values (p_employee_id, p_message_id, thread_value) on conflict do nothing;
  else
    delete from public.ansar_chat_starred_messages
    where employee_id = p_employee_id and message_id = p_message_id;
  end if;
end;
$$;

create or replace function public.ansar_toggle_chat_pin(
  p_employee_id text, p_message_id text, p_pinned boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare thread_value text;
begin
  select message.thread_id::text into thread_value
  from public.ansar_chat_messages message where message.id::text = p_message_id;
  if not public.ansar_chat_can_manage(p_employee_id, thread_value) then raise exception 'التثبيت متاح لمشرفي المحادثة'; end if;
  if p_pinned then
    if (select count(*) from public.ansar_chat_pinned_messages pin where pin.thread_id = thread_value) >= 3 then
      raise exception 'يمكن تثبيت ثلاث رسائل كحد أقصى';
    end if;
    insert into public.ansar_chat_pinned_messages (thread_id, message_id, pinned_by)
    values (thread_value, p_message_id, p_employee_id) on conflict do nothing;
  else
    delete from public.ansar_chat_pinned_messages where thread_id = thread_value and message_id = p_message_id;
  end if;
end;
$$;

create or replace function public.ansar_vote_chat_poll(
  p_employee_id text, p_poll_id text, p_option_ids jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare poll_row record; option_value text;
begin
  select * into poll_row from public.ansar_chat_polls poll where poll.id = p_poll_id;
  if not found or poll_row.closed_at is not null then raise exception 'الاستبيان مغلق أو غير موجود'; end if;
  if not public.ansar_chat_is_member(p_employee_id, poll_row.thread_id) then raise exception 'غير مصرح'; end if;
  if jsonb_typeof(p_option_ids) <> 'array' then raise exception 'الخيارات غير صالحة'; end if;
  if not poll_row.allows_multiple and jsonb_array_length(p_option_ids) > 1 then raise exception 'اختر إجابة واحدة'; end if;
  delete from public.ansar_chat_poll_votes where poll_id = p_poll_id and employee_id = p_employee_id;
  for option_value in select jsonb_array_elements_text(p_option_ids)
  loop
    if exists (select 1 from public.ansar_chat_poll_options option_row where option_row.id = option_value and option_row.poll_id = p_poll_id) then
      insert into public.ansar_chat_poll_votes (poll_id, option_id, employee_id)
      values (p_poll_id, option_value, p_employee_id) on conflict do nothing;
    end if;
  end loop;
end;
$$;

create or replace function public.ansar_close_chat_poll(
  p_employee_id text, p_poll_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare poll_row record;
begin
  select * into poll_row
  from public.ansar_chat_polls poll
  where poll.id = p_poll_id
  for update;
  if not found then raise exception 'الاستبيان غير موجود'; end if;
  if poll_row.created_by <> p_employee_id
     and not public.ansar_chat_can_manage(p_employee_id, poll_row.thread_id) then
    raise exception 'إغلاق الاستبيان متاح لمنشئه أو مشرف المحادثة';
  end if;
  update public.ansar_chat_polls
  set closed_at = coalesce(closed_at, now()), closed_by = coalesce(closed_by, p_employee_id)
  where id = p_poll_id;
end;
$$;

create or replace function public.ansar_manage_chat_member_v2(
  p_actor_id text,
  p_thread_id text,
  p_member_id text,
  p_action text,
  p_role text default 'member'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare thread_row record;
begin
  select * into thread_row
  from public.ansar_chat_threads thread
  where thread.id::text = p_thread_id
  for update;
  if not found then raise exception 'المحادثة غير موجودة'; end if;
  if thread_row.channel_kind in ('announcement', 'branch') then
    raise exception 'عضوية القنوات الرسمية تُدار تلقائياً';
  end if;
  if not public.ansar_chat_can_manage(p_actor_id, p_thread_id) then
    raise exception 'إدارة الأعضاء متاحة لمشرفي المجموعة';
  end if;
  if p_action = 'add' then
    insert into public.ansar_chat_participants (thread_id, employee_id, role)
    select thread_row.id, employee.id, case when p_role = 'admin' then 'admin' else 'member' end
    from public.ansar_employees employee
    where employee.id::text = p_member_id and coalesce(employee.is_active, true) = true
    on conflict (thread_id, employee_id) do update set role = excluded.role;
  elsif p_action = 'remove' then
    if p_member_id = p_actor_id then raise exception 'استخدم مغادرة المجموعة للخروج منها'; end if;
    delete from public.ansar_chat_participants
    where thread_id::text = p_thread_id and employee_id::text = p_member_id;
  elsif p_action = 'role' then
    update public.ansar_chat_participants
    set role = case when p_role = 'admin' then 'admin' else 'member' end
    where thread_id::text = p_thread_id and employee_id::text = p_member_id;
  else
    raise exception 'الإجراء غير معروف';
  end if;
end;
$$;

-- صفحات صغيرة موحدة بدلاً من تحميل تاريخ المحادثة كاملاً.
create or replace function public.ansar_chat_messages_page_v2(
  p_employee_id text,
  p_thread_id text,
  p_before timestamptz default null,
  p_limit integer default 80
)
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare result_value jsonb;
begin
  if not public.ansar_chat_is_member(p_employee_id, p_thread_id) then
    raise exception 'غير مصرح بفتح هذه المحادثة';
  end if;
  select coalesce(jsonb_agg(to_jsonb(page_row) order by page_row.created_at, page_row.id), '[]'::jsonb)
  into result_value
  from (
    select message.*
    from public.ansar_chat_messages message
    where message.thread_id::text = p_thread_id
      and (p_before is null or message.created_at < p_before)
      and not exists (
        select 1
        from public.ansar_chat_message_hidden hidden
        where hidden.message_id::text = message.id::text
          and hidden.employee_id::text = p_employee_id
      )
    order by message.created_at desc, message.id desc
    limit greatest(1, least(coalesce(p_limit, 80), 120))
  ) page_row;
  return result_value;
end;
$$;

create or replace function public.ansar_chat_threads_page_v2(
  p_employee_id text,
  p_before timestamptz default null,
  p_limit integer default 60
)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(jsonb_agg(page_row.payload order by page_row.updated_at desc), '[]'::jsonb)
  from (
    select
      thread.updated_at,
      to_jsonb(thread)
        || jsonb_build_object(
          'participant_settings', to_jsonb(participant),
          'last_message', to_jsonb(last_message),
          'unread_count', (
            select count(*)
            from public.ansar_chat_message_receipts receipt
            where receipt.thread_id::text = thread.id::text
              and receipt.employee_id::text = p_employee_id
              and receipt.status <> 'read'
          )
        ) as payload
    from public.ansar_chat_threads thread
    left join public.ansar_chat_participants participant
      on participant.thread_id::text = thread.id::text
     and participant.employee_id::text = p_employee_id
    left join lateral (
      select message.*
      from public.ansar_chat_messages message
      where message.thread_id::text = thread.id::text
      order by message.created_at desc, message.id desc
      limit 1
    ) last_message on true
    where coalesce(thread.is_active, true) = true
      and (p_before is null or thread.updated_at < p_before)
      and (thread.thread_type = 'general' or participant.employee_id is not null)
    order by thread.updated_at desc
    limit greatest(1, least(coalesce(p_limit, 60), 100))
  ) page_row;
$$;

create or replace function public.ansar_acknowledge_chat_announcement(
  p_employee_id text, p_message_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare thread_value text; ack_required boolean;
begin
  select message.thread_id::text, message.requires_ack
  into thread_value, ack_required
  from public.ansar_chat_messages message where message.id::text = p_message_id;
  if not ack_required then raise exception 'هذا الإعلان لا يطلب تأكيد الاطلاع'; end if;
  if not public.ansar_chat_is_member(p_employee_id, thread_value) then raise exception 'غير مصرح'; end if;
  insert into public.ansar_chat_announcement_acknowledgements (message_id, employee_id)
  values (p_message_id, p_employee_id) on conflict do nothing;
end;
$$;

-- ينشئ القنوات الناقصة فقط ويزامن عضويتها دون المساس بالمحادثات العادية.
create or replace function public.ansar_sync_system_chat_channels()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare announcement_id text; branch_row record; branch_thread_id text; created_count integer := 0;
begin
  select thread.id::text into announcement_id
  from public.ansar_chat_threads thread where thread.system_key = 'announcements' limit 1;
  if announcement_id is null then
    insert into public.ansar_chat_threads (
      title, thread_type, channel_kind, posting_policy, system_key, is_active
    ) values ('الإعلانات الرسمية', 'group', 'announcement', 'admins', 'announcements', true)
    returning id::text into announcement_id;
    created_count := created_count + 1;
  end if;
  insert into public.ansar_chat_participants (thread_id, employee_id, role)
  select announcement_thread.id, employee.id,
    case when employee.role = 'admin' or coalesce(employee.can_manage_all_branches, false) then 'admin' else 'member' end
  from public.ansar_chat_threads announcement_thread
  cross join public.ansar_employees employee
  where announcement_thread.id::text = announcement_id
    and coalesce(employee.is_active, true) = true
  on conflict (thread_id, employee_id) do update set role = excluded.role;

  for branch_row in
    select branch.sto_num, branch.name from public.ansar_branches branch where coalesce(branch.is_active, true) = true
  loop
    select thread.id::text into branch_thread_id
    from public.ansar_chat_threads thread where thread.system_key = 'branch:' || branch_row.sto_num::text limit 1;
    if branch_thread_id is null then
      insert into public.ansar_chat_threads (
        title, thread_type, channel_kind, branch_num, posting_policy, system_key, is_active
      ) values (
        'قناة ' || coalesce(branch_row.name, branch_row.sto_num::text),
        'group', 'branch', branch_row.sto_num, 'members', 'branch:' || branch_row.sto_num::text, true
      ) returning id::text into branch_thread_id;
      created_count := created_count + 1;
    end if;
    delete from public.ansar_chat_participants participant
    where participant.thread_id::text = branch_thread_id
      and not exists (
        select 1 from public.ansar_employees employee
        where employee.id::text = participant.employee_id::text
          and coalesce(employee.is_active, true) = true
          and (employee.branch_num = branch_row.sto_num or employee.role = 'admin' or coalesce(employee.can_manage_all_branches, false))
      );
    insert into public.ansar_chat_participants (thread_id, employee_id, role)
    select branch_thread.id, employee.id,
      case when employee.role in ('admin', 'branch_manager') or coalesce(employee.can_manage_all_branches, false) then 'admin' else 'member' end
    from public.ansar_chat_threads branch_thread
    cross join public.ansar_employees employee
    where branch_thread.id::text = branch_thread_id
      and coalesce(employee.is_active, true) = true
      and (employee.branch_num = branch_row.sto_num or employee.role = 'admin' or coalesce(employee.can_manage_all_branches, false))
    on conflict (thread_id, employee_id) do update set role = excluded.role;
  end loop;
  return jsonb_build_object('created', created_count, 'announcements_thread_id', announcement_id);
end;
$$;

create or replace function public.ansar_chat_v2_sync_system_memberships()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.ansar_sync_system_chat_channels();
  return null;
end;
$$;

drop trigger if exists ansar_chat_v2_employee_membership_trigger on public.ansar_employees;
create trigger ansar_chat_v2_employee_membership_trigger
after insert or update
on public.ansar_employees
for each statement execute function public.ansar_chat_v2_sync_system_memberships();

drop trigger if exists ansar_chat_v2_branch_membership_trigger on public.ansar_branches;
create trigger ansar_chat_v2_branch_membership_trigger
after insert or update
on public.ansar_branches
for each statement execute function public.ansar_chat_v2_sync_system_memberships();

-- Realtime والأذونات للجداول الجديدة.
alter table public.ansar_chat_inbox_events replica identity full;
alter table public.ansar_chat_message_reactions replica identity full;
alter table public.ansar_chat_pinned_messages replica identity full;
alter table public.ansar_chat_polls replica identity full;
alter table public.ansar_chat_poll_votes replica identity full;
alter table public.ansar_chat_announcement_acknowledgements replica identity full;

do $$ begin alter publication supabase_realtime add table public.ansar_chat_inbox_events;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.ansar_chat_message_reactions;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.ansar_chat_pinned_messages;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.ansar_chat_poll_votes;
exception when duplicate_object then null; end $$;

grant select, insert, update, delete on table
  public.ansar_chat_inbox_events,
  public.ansar_chat_message_reactions,
  public.ansar_chat_starred_messages,
  public.ansar_chat_pinned_messages,
  public.ansar_chat_polls,
  public.ansar_chat_poll_options,
  public.ansar_chat_poll_votes,
  public.ansar_chat_announcement_acknowledgements
to anon, authenticated, service_role;

grant usage, select on sequence public.ansar_chat_inbox_events_id_seq to anon, authenticated, service_role;
grant execute on function public.ansar_chat_is_member(text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_chat_can_manage(text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_send_chat_message_v2(text, text, text, text, text, jsonb, text, jsonb, boolean, text, jsonb) to anon, authenticated, service_role;
grant execute on function public.ansar_send_chat_reply(text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_edit_chat_message_v2(text, text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_delete_chat_message_v2(text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_set_chat_reaction(text, text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_toggle_chat_star(text, text, boolean) to anon, authenticated, service_role;
grant execute on function public.ansar_toggle_chat_pin(text, text, boolean) to anon, authenticated, service_role;
grant execute on function public.ansar_vote_chat_poll(text, text, jsonb) to anon, authenticated, service_role;
grant execute on function public.ansar_close_chat_poll(text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_manage_chat_member_v2(text, text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_acknowledge_chat_announcement(text, text) to anon, authenticated, service_role;
grant execute on function public.ansar_chat_messages_page_v2(text, text, timestamptz, integer) to anon, authenticated, service_role;
grant execute on function public.ansar_chat_threads_page_v2(text, timestamptz, integer) to anon, authenticated, service_role;
grant execute on function public.ansar_sync_system_chat_channels() to anon, authenticated, service_role;

select public.ansar_sync_system_chat_channels();
