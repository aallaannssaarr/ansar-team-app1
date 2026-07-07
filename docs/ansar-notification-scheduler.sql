-- Run this in Supabase SQL Editor after deploying the send-notifications Edge Function.
-- It calls the sender every minute so pending rows become real Firebase notifications.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule('ansar-send-notifications-every-minute');
exception
  when others then
    null;
end $$;

select cron.schedule(
  'ansar-send-notifications-every-minute',
  '* * * * *',
  $$
  select
    net.http_post(
      url := 'https://dktukfkitlfwpporhjsm.supabase.co/functions/v1/send-notifications',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := '{"source":"cron"}'::jsonb
    );
  $$
);
