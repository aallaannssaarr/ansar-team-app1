-- جدول فروع خاص بتطبيق فريق الأنصار
-- هذا لا يعدل جدول branches القديم، بل يسمح للتطبيق بإضافة/تعديل/إخفاء الفروع بأمان.

create table if not exists public.ansar_branches (
  sto_num integer primary key,
  name text not null,
  is_active boolean not null default true,
  created_by uuid references public.ansar_employees(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists ansar_branches_active_idx
  on public.ansar_branches(is_active, sto_num);

drop trigger if exists ansar_branches_set_updated_at on public.ansar_branches;
create trigger ansar_branches_set_updated_at
before update on public.ansar_branches
for each row execute function public.ansar_set_updated_at();

-- مثال اختياري إذا لم تكن لديك فروع في الجدول القديم:
-- insert into public.ansar_branches (sto_num, name, is_active)
-- values (1, 'الفرع الرئيسي', true)
-- on conflict (sto_num) do update set name = excluded.name, is_active = true;
