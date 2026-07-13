-- تطوير دردشة فريق الأنصار
-- هذا الملف يضيف أعمدة فقط إلى جداول الدردشة الخاصة بالتطبيق.
-- لا يغير أي جدول من جداول الكتب أو الحسابات أو المبيعات.

alter table public.ansar_chat_messages
  add column if not exists edited_at timestamptz,
  add column if not exists edited_by text,
  add column if not exists deleted_by text,
  add column if not exists reply_to_id text,
  add column if not exists forwarded_from_id text;

alter table public.ansar_chat_threads
  add column if not exists description text,
  add column if not exists avatar_url text;

alter table public.ansar_chat_participants
  add column if not exists is_muted boolean not null default false,
  add column if not exists last_read_at timestamptz;

create index if not exists ansar_chat_messages_reply_to_idx
  on public.ansar_chat_messages (reply_to_id)
  where reply_to_id is not null;

create index if not exists ansar_chat_messages_forwarded_from_idx
  on public.ansar_chat_messages (forwarded_from_id)
  where forwarded_from_id is not null;

create index if not exists ansar_chat_participants_employee_thread_idx
  on public.ansar_chat_participants (employee_id, thread_id);

-- تأكد من وصول تحديثات الرسائل والمشاركين فورياً إلى الأجهزة.
do $$
begin
  alter publication supabase_realtime add table public.ansar_chat_messages;
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.ansar_chat_threads;
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.ansar_chat_participants;
exception
  when duplicate_object then null;
end $$;
