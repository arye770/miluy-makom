# מילוי מקום

מערכת לניהול שעות מילוי מקום.

- `index.html`: המערכת
- `setup.sql`: הגדרת השרת ב-Supabase
- `supabase/functions/read-file/index.ts`: קריאת קבצים (מערכת שעות, אישורי מחלה, צילומי תקן) דרך Claude. צריך סוד `ANTHROPIC_API_KEY` ב-Supabase.
