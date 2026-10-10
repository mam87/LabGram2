# LabGram UI tests

`audit.py` runs the real `index.html` in headless Chromium against an in-memory
Supabase mock (`mock-supabase.js`). It covers auth screens, posting with image
upload, likes, comments, delete, report, profile/settings, follow, specialty
filter, explore, notifications, owner dashboard actions, navigation, logout,
empty/error/setup states, mobile overflow, and a throttled-CPU load check.

```bash
pip install playwright && python -m playwright install chromium
python3 -m http.server 8765 --bind 127.0.0.1 &   # from the repo root
python3 tests/audit.py
```

What the mock does **not** cover: real Supabase auth (email delivery, sessions),
server-side search filtering, Row Level Security and storage rules. Those are
verified directly against the database with rolled-back SQL transactions — see
the security section of the root README.

Known expected failure: "LTR/English UI" — the interface is Arabic-only.
