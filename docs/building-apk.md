# بناء APK للتجربة

## GitHub Actions

بعد رفع المشروع إلى GitHub:

1. افتح تبويب `Actions`.
2. اختر `Android Debug APK`.
3. اضغط `Run workflow`.
4. بعد انتهاء البناء، حمل artifact باسم `ansar-team-debug-apk`.

## Codemagic

1. اربط مستودع GitHub مع Codemagic.
2. اختر workflow باسم `Android Debug APK`.
3. شغل البناء.
4. حمل `app-debug.apk` من artifacts.

هذه النسخة Debug للتجربة الداخلية. عندما نصل لمرحلة النشر سنضيف توقيع Release.
