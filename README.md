# تطبيق فريق الأنصار

هذا مشروع Flutter أولي لتطبيق موبايل حقيقي، وليس WebView.

## يحتوي على

- تسجيل دخول موظف عبر `username` من جدول `ansar_employees`.
- لوحة رئيسية حسب صلاحيات الموظف.
- تسجيل حضور وانصراف في `ansar_attendance_logs`.
- إدارة موظفين للمدير.
- بداية صفحات المناقلات والدردشة والإشعارات.
- ربط Supabase عبر الجداول الجديدة `ansar_*` والجداول الحالية للقراءة.

## ملاحظات مهمة

- الإشعارات الحقيقية تحتاج ملف Firebase الخاص بأندرويد:
  `android/app/google-services.json`
- لم أضع هذا الملف لأنه خاص بحساب Firebase عندك.
- التطبيق يستخدم `anon key` فقط.
- الجداول القديمة مثل `products`, `branches`, `product_stock` تقرأ فقط.

## البناء

على جهاز أو خدمة فيها Flutter:

```bash
flutter pub get
flutter build apk --release
```
