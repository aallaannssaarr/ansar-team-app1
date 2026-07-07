-- صلاحيات صور موظفي تطبيق فريق الأنصار
-- نفذ هذا الملف إذا ظهرت رسالة "تعذر رفع الصورة" عند تغيير صورة الحساب.

insert into storage.buckets (id, name, public)
values ('ansar-avatars', 'ansar-avatars', true)
on conflict (id) do update set public = true;

drop policy if exists "ansar avatars public read" on storage.objects;
create policy "ansar avatars public read"
on storage.objects for select
using (bucket_id = 'ansar-avatars');

drop policy if exists "ansar avatars upload" on storage.objects;
create policy "ansar avatars upload"
on storage.objects for insert
with check (bucket_id = 'ansar-avatars');

drop policy if exists "ansar avatars update" on storage.objects;
create policy "ansar avatars update"
on storage.objects for update
using (bucket_id = 'ansar-avatars')
with check (bucket_id = 'ansar-avatars');
