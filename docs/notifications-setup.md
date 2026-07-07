# Notifications setup

This app now has the mobile side and the Supabase sender side for Firebase push notifications.

## What is already wired

- Android asks for notification permission.
- Each logged-in employee device is saved in `ansar_device_tokens`.
- Attendance check-in/check-out creates branch notifications.
- Transfer creation/status/item updates create targeted notifications.
- Chat messages create notifications for conversation participants. General chat notifies all active employees except the sender.
- `supabase/functions/send-notifications` sends pending rows from `ansar_notification_queue` through Firebase Cloud Messaging.

## One-time setup

1. In Firebase Console, open the `ansar team` project.
2. Go to Project settings, then Service accounts.
3. Press Generate new private key and download the JSON file.
4. In GitHub, open the repository settings, then Secrets and variables, then Actions.
5. Add these repository secrets:
   - `SUPABASE_ACCESS_TOKEN`: a Supabase access token from your Supabase account settings.
   - `FIREBASE_SERVICE_ACCOUNT_JSON`: the full content of the Firebase private key JSON file.
6. In GitHub Actions, run `Deploy Notification Sender`.
7. In Supabase SQL Editor, run `docs/ansar-notification-scheduler.sql`.

After this, build and install the APK on two phones, log in on both, and test attendance, transfers, and chat.
