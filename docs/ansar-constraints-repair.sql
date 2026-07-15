-- إصلاح قيود حالات المناقلات وأنواع رسائل الدردشة.
-- لا يعدل أي سجل ولا يحذف أي بيانات، ويمكن تنفيذه أكثر من مرة.

alter table public.ansar_transfer_orders
  drop constraint if exists ansar_transfer_orders_status_check;
alter table public.ansar_transfer_orders
  add constraint ansar_transfer_orders_status_check
  check (status in (
    'draft',
    'submitted',
    'approved',
    'partially_available',
    'preparing',
    'in_delivery',
    'received',
    'completed',
    'rejected',
    'cancelled'
  )) not valid;

alter table public.ansar_chat_messages
  drop constraint if exists ansar_chat_messages_message_type_check;
alter table public.ansar_chat_messages
  add constraint ansar_chat_messages_message_type_check
  check (message_type in (
    'text',
    'attachment',
    'transfer',
    'forwarded',
    'system'
  )) not valid;

notify pgrst, 'reload schema';

select 'ansar constraints repaired successfully' as result;
