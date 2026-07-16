# بناء نسخة فريق الأنصار التجريبية

النسخة التجريبية مستقلة عن التطبيق المستقر، ويمكن تثبيتهما معاً على الهاتف نفسه.

## إعداد Firebase لمرة واحدة

1. افتح مشروع `ansar team` في Firebase.
2. أضف تطبيق Android جديداً بالمعرّف `com.example.ansar_team_app.beta`.
3. اجعل اسم التطبيق `فريق الأنصار التجريبي` ثم نزّل ملف `google-services.json`.
4. في مستودع GitHub افتح `Settings > Secrets and variables > Actions`.
5. أضف سراً باسم `FIREBASE_BETA_GOOGLE_SERVICES_JSON` والصق محتوى الملف كاملاً داخله.

## ملفات البناء

- التطبيق المستقر: `ansar-team-stable-debug.apk` من مسار `Android Debug APK`.
- التطبيق التجريبي: `ansar-team-beta-debug.apk` من مسار `Android Beta APK`.

لا تُحفظ مفاتيح Firebase داخل المستودع، ولا تُجرى أي تغييرات على جداول Supabase من أجل نسخة التصميم.
