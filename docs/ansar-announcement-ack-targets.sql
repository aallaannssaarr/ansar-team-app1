-- Per-employee acknowledgement targets for official announcements.
-- Safe to run more than once. Existing messages and acknowledgements are preserved.

alter table public.ansar_chat_messages
  add column if not exists ack_target_scope text not null default 'all';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'ansar_chat_messages_ack_target_scope_check'
      and conrelid = 'public.ansar_chat_messages'::regclass
  ) then
    alter table public.ansar_chat_messages
      add constraint ansar_chat_messages_ack_target_scope_check
      check (ack_target_scope in ('all', 'selected'));
  end if;
end $$;

create table if not exists public.ansar_chat_announcement_targets (
  message_id text not null,
  employee_id text not null,
  assigned_by text,
  assigned_at timestamptz not null default now(),
  primary key (message_id, employee_id)
);

create index if not exists ansar_chat_announcement_targets_employee_idx
  on public.ansar_chat_announcement_targets (employee_id, assigned_at desc);

-- Existing acknowledgement-required announcements are treated as required for
-- every active member except their sender, matching the previous behaviour.
insert into public.ansar_chat_announcement_targets (
  message_id, employee_id, assigned_by, assigned_at
)
select
  message.id::text,
  employee.id::text,
  message.sender_id::text,
  coalesce(message.created_at, now())
from public.ansar_chat_messages message
join public.ansar_chat_threads thread
  on thread.id::text = message.thread_id::text
join public.ansar_employees employee
  on coalesce(employee.is_active, true) = true
where message.requires_ack = true
  and thread.channel_kind = 'announcement'
  and employee.id::text <> message.sender_id::text
  and public.ansar_chat_is_member(employee.id::text, message.thread_id::text)
on conflict (message_id, employee_id) do nothing;

create or replace function public.ansar_send_chat_message_v3(
  p_employee_id text,
  p_thread_id text,
  p_client_message_id text,
  p_body text default '',
  p_message_type text default 'text',
  p_attachments jsonb default '[]'::jsonb,
  p_reply_to_id text default null,
  p_mentions jsonb default '[]'::jsonb,
  p_requires_ack boolean default false,
  p_ack_target_employee_ids jsonb default null,
  p_forwarded_from_id text default null,
  p_poll jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result_value jsonb;
  message_value text;
  target_scope text := 'all';
  target_value text;
  target_count integer := 0;
  thread_kind text;
begin
  if p_requires_ack then
    select thread.channel_kind into thread_kind
    from public.ansar_chat_threads thread
    where thread.id::text = p_thread_id
      and coalesce(thread.is_active, true) = true;

    if thread_kind is distinct from 'announcement' then
      raise exception 'تأكيد الاطلاع متاح في الإعلانات الرسمية فقط';
    end if;
  end if;

  result_value := public.ansar_send_chat_message_v2(
    p_employee_id => p_employee_id,
    p_thread_id => p_thread_id,
    p_client_message_id => p_client_message_id,
    p_body => p_body,
    p_message_type => p_message_type,
    p_attachments => coalesce(p_attachments, '[]'::jsonb),
    p_reply_to_id => p_reply_to_id,
    p_mentions => coalesce(p_mentions, '[]'::jsonb),
    p_requires_ack => p_requires_ack,
    p_forwarded_from_id => p_forwarded_from_id,
    p_poll => p_poll
  );

  message_value := result_value->'message'->>'id';
  if message_value is null or not p_requires_ack then
    return result_value;
  end if;

  if p_ack_target_employee_ids is not null then
    if jsonb_typeof(p_ack_target_employee_ids) <> 'array' then
      raise exception 'قائمة الموظفين المطلوب منهم الاطلاع غير صالحة';
    end if;
    target_scope := 'selected';
  end if;

  update public.ansar_chat_messages
  set ack_target_scope = target_scope
  where id::text = message_value;

  delete from public.ansar_chat_announcement_targets
  where message_id = message_value;

  if target_scope = 'all' then
    insert into public.ansar_chat_announcement_targets (
      message_id, employee_id, assigned_by
    )
    select message_value, employee.id::text, p_employee_id
    from public.ansar_employees employee
    where coalesce(employee.is_active, true) = true
      and employee.id::text <> p_employee_id
      and public.ansar_chat_is_member(employee.id::text, p_thread_id)
    on conflict (message_id, employee_id) do nothing;
  else
    for target_value in
      select distinct btrim(value)
      from jsonb_array_elements_text(p_ack_target_employee_ids)
      where nullif(btrim(value), '') is not null
        and btrim(value) <> p_employee_id
    loop
      if not exists (
        select 1
        from public.ansar_employees employee
        where employee.id::text = target_value
          and coalesce(employee.is_active, true) = true
          and public.ansar_chat_is_member(employee.id::text, p_thread_id)
      ) then
        raise exception 'أحد الموظفين المحددين غير نشط أو غير عضو في القناة';
      end if;

      insert into public.ansar_chat_announcement_targets (
        message_id, employee_id, assigned_by
      ) values (
        message_value, target_value, p_employee_id
      ) on conflict (message_id, employee_id) do nothing;
    end loop;
  end if;

  select count(*) into target_count
  from public.ansar_chat_announcement_targets target
  where target.message_id = message_value;

  if target_count = 0 then
    raise exception 'اختر موظفاً واحداً على الأقل لتأكيد الاطلاع';
  end if;

  return jsonb_set(
    result_value,
    '{message}',
    coalesce(result_value->'message', '{}'::jsonb) || jsonb_build_object(
      'ack_target_scope', target_scope,
      'ack_target_count', target_count
    ),
    true
  );
end;
$$;

create or replace function public.ansar_acknowledge_chat_announcement(
  p_employee_id text, p_message_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  thread_value text;
  ack_required boolean;
begin
  select message.thread_id::text, message.requires_ack
  into thread_value, ack_required
  from public.ansar_chat_messages message
  where message.id::text = p_message_id;

  if not coalesce(ack_required, false) then
    raise exception 'هذا الإعلان لا يطلب تأكيد الاطلاع';
  end if;
  if not public.ansar_chat_is_member(p_employee_id, thread_value) then
    raise exception 'غير مصرح';
  end if;
  if not exists (
    select 1
    from public.ansar_chat_announcement_targets target
    where target.message_id = p_message_id
      and target.employee_id = p_employee_id
  ) then
    raise exception 'هذا الإعلان غير موجه إليك لتأكيد الاطلاع';
  end if;

  insert into public.ansar_chat_announcement_acknowledgements (
    message_id, employee_id
  ) values (
    p_message_id, p_employee_id
  ) on conflict (message_id, employee_id) do nothing;
end;
$$;

drop trigger if exists ansar_chat_v3_target_change_trigger
  on public.ansar_chat_announcement_targets;
create trigger ansar_chat_v3_target_change_trigger
after insert or update or delete on public.ansar_chat_announcement_targets
for each row execute function public.ansar_chat_v2_emit_related_change();

alter table public.ansar_chat_announcement_targets replica identity full;
do $$
begin
  alter publication supabase_realtime
    add table public.ansar_chat_announcement_targets;
exception when duplicate_object then
  null;
end $$;

grant select, insert, update, delete
  on table public.ansar_chat_announcement_targets
  to anon, authenticated, service_role;

grant execute on function public.ansar_send_chat_message_v3(
  text, text, text, text, text, jsonb, text, jsonb, boolean, jsonb, text, jsonb
) to anon, authenticated, service_role;

grant execute on function public.ansar_acknowledge_chat_announcement(text, text)
  to anon, authenticated, service_role;
