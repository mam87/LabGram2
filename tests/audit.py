"""LabGram UI audit — runs the real index.html in Chromium against an in-memory Supabase mock.
Each check prints PASS/FAIL with evidence. Usage: python3 audit.py <index.html>"""
import sys, pathlib, base64, time
from playwright.sync_api import sync_playwright
import re as _re
def strip_sri(route):
    r = route.fetch(); body = _re.sub(r' integrity="[^"]+"', '', r.text())
    route.fulfill(response=r, body=body)

URL = 'http://127.0.0.1:8765/index.html'
MOCK = (pathlib.Path(__file__).parent / 'mock-supabase.js').read_text()
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
results = []

def check(name, ok, evidence=''):
    results.append((name, bool(ok), evidence))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{evidence}]' if evidence else ''))

with sync_playwright() as p:
    b = p.chromium.launch()

    def page(q='?signed', h='#/', vp=(1400, 900)):
        ctx = b.new_context(viewport={'width': vp[0], 'height': vp[1]})
        ctx.route('**/vendor/supabase-js-*.js', lambda r: r.fulfill(body=MOCK, content_type='application/javascript'))
        ctx.route('**/fonts.g*/**', lambda r: r.abort()); ctx.route('**/index.html*', strip_sri)
        pg = ctx.new_page(); pg._errs = []
        pg.on('pageerror', lambda e: pg._errs.append(str(e)))
        pg.on('dialog', lambda d: d.accept())
        pg.goto(URL + q + h); pg.wait_for_timeout(700)
        return pg

    # ---------- AUTH ----------
    pg = page('', '#/')
    check('auth: login screen renders when signed out', pg.locator('#fEmail').count() == 1)
    pg.click('#fBtn'); pg.wait_for_timeout(150)
    check('auth: empty login shows validation', 'أدخل البريد' in pg.inner_text('#fMsg'), pg.inner_text('#fMsg'))
    pg.fill('#fEmail', 'a@b.co'); pg.fill('#fPass', 'wrongpass'); pg.click('#fBtn'); pg.wait_for_timeout(300)
    check('auth: bad credentials mapped to Arabic message', 'غير صحيحة' in pg.inner_text('#fMsg'), pg.inner_text('#fMsg'))
    pg.click('text=حساب جديد'); pg.wait_for_timeout(150)
    pg.fill('#fUser', 'ab'); pg.click('#fBtn'); pg.wait_for_timeout(150)
    check('register: short username rejected', '3–30' in pg.inner_text('#fMsg'), pg.inner_text('#fMsg'))
    pg.fill('#fUser', 'MAM87'); pg.fill('#fName', 'X'); pg.fill('#fEmail', 'x@y.co'); pg.fill('#fPass', '123456'); pg.click('#fBtn'); pg.wait_for_timeout(400)
    check('register: username taken (case-insensitive) rejected', 'محجوز' in pg.inner_text('#fMsg'), pg.inner_text('#fMsg'))
    pg.goto(URL + '#/'); pg.wait_for_timeout(500); pg.click('text=حساب جديد'); pg.wait_for_timeout(150)
    pg.fill('#fUser', 'new_user1'); pg.fill('#fName', 'X'); pg.fill('#fEmail', 'x@y.co'); pg.fill('#fPass', '123456'); pg.click('#fBtn'); pg.wait_for_timeout(400)
    check('register: success asks for email confirmation', 'تفعيل' in pg.inner_text('#fMsg'), pg.inner_text('#fMsg'))
    pg.click('text=تسجيل الدخول >> nth=0'); pg.wait_for_timeout(150); pg.click('text=استعادتها'); pg.wait_for_timeout(150)
    pg.fill('#fEmail', 'x@y.co'); pg.click('#fBtn'); pg.wait_for_timeout(300)
    check('recovery: request shows confirmation', 'رسالة' in pg.inner_text('#fMsg'), pg.inner_text('#fMsg'))
    check('auth: no JS errors', not pg._errs, '; '.join(pg._errs))

    # ---------- FEED / POSTS ----------
    pg = page()
    n0 = pg.locator('.post').count()
    check('feed: posts render', n0 >= 3, f'{n0} posts')
    check('feed: pinned post shown first', pg.locator('.post').first.locator('.pin-tag').count() == 1)
    pid = pg.evaluate('__DB.lg_posts[2].id')
    before = pg.inner_text(f'#like-{pid} span'); pg.click(f'#like-{pid}'); pg.wait_for_timeout(200)
    after = pg.inner_text(f'#like-{pid} span')
    check('like: toggles count optimistically and persists', before != after and pg.evaluate(f"__DB.lg_likes.some(l=>l.post_id=='{pid}')"), f'{before}->{after}')
    pg.goto(URL + '?signed#/new'); pg.wait_for_timeout(500)
    pg.set_input_files('#file', files=[{'name': 'cells.png', 'mimeType': 'image/png', 'buffer': PNG}]); pg.wait_for_timeout(200)
    check('create: image preview shown', pg.locator('#drop img').count() == 1)
    pg.fill('#body', 'حالة اختبار'); pg.click('#pubBtn'); pg.wait_for_timeout(900)
    up = pg.evaluate('__UPLOADS'); me = pg.evaluate("__DB.lg_profiles[0].id")
    check('upload: file stored under own user folder', up and up[0]['path'].startswith(me + '/posts/'), up[0]['path'] if up else 'none')
    check('create: post with image appears in feed', pg.evaluate("__DB.lg_posts.some(p=>p.body=='حالة اختبار' && p.image_url)") and pg.locator('text=حالة اختبار').count() >= 1)
    pg.goto(URL + '?signed#/new'); pg.wait_for_timeout(400); pg.click('#pubBtn'); pg.wait_for_timeout(300)
    check('create: empty post blocked', pg.evaluate("document.getElementById('toast').textContent").startswith('اكتب'))
    # comment
    pg.goto(URL + f'?signed#/p/{pid}'); pg.wait_for_timeout(600)
    c0 = pg.locator('.cmt').count(); pg.fill('#cIn', 'رد تجريبي'); pg.click('#cBtn'); pg.wait_for_timeout(300)
    check('comment: added to post', pg.locator('.cmt').count() == c0 + 1, f'{c0}->{pg.locator(".cmt").count()}')
    # delete own post
    own = pg.evaluate("__DB.lg_posts.find(p=>p.body=='حالة اختبار').id")
    pg.goto(URL + '?signed#/'); pg.wait_for_timeout(600)
    pg.click(f'#post-{own} button[title="حذف"]'); pg.wait_for_timeout(600)
    check('delete: own post removed', not pg.evaluate(f"__DB.lg_posts.some(p=>p.id=='{own}')"))
    # report
    other = pg.evaluate("__DB.lg_posts.find(p=>p.user_id!=__DB.lg_profiles[0].id).id")
    pg.click(f'#post-{other} button[title="إبلاغ"]'); pg.wait_for_timeout(150)
    pg.click('.reasons button >> nth=1'); pg.wait_for_timeout(300)
    check('report: reason submitted', pg.evaluate(f"__DB.lg_reports.some(r=>r.post_id=='{other}' && r.reporter_id==__DB.lg_profiles[0].id)"))
    check('posts: no JS errors', not pg._errs, '; '.join(pg._errs))

    # ---------- PROFILE / SETTINGS ----------
    pg = page(h='#/settings')
    pg.fill('#sName', 'أنس المعدّل'); pg.fill('#sBio', 'نبذة جديدة'); pg.click('.covers button[data-k="ocean"]'); pg.click('#fBtn'); pg.wait_for_timeout(600)
    pr = pg.evaluate('__DB.lg_profiles[0]')
    check('profile edit: saved name/bio/cover', pr['display_name'] == 'أنس المعدّل' and pr['bio'] == 'نبذة جديدة' and pr['cover'] == 'ocean')
    check('profile edit: redirected to profile page', pg.evaluate('location.hash') == '#/u/mam87')
    pg.goto(URL + '?signed#/settings'); pg.wait_for_timeout(400)
    pg.fill('#sPass', '123'); pg.click('#pBtn'); pg.wait_for_timeout(150)
    check('password change: short password rejected', '6' in pg.inner_text('#pMsg'))
    pg.fill('#sPass', 'NewPass123'); pg.click('#pBtn'); pg.wait_for_timeout(300)
    check('password change: calls auth.updateUser', pg.evaluate('__PW && __PW.password') == 'NewPass123')
    # follow from another profile
    pg.goto(URL + '?signed#/u/omar.hema'); pg.wait_for_timeout(600)
    f0 = pg.inner_text('#fcount'); pg.click('#fbtn'); pg.wait_for_timeout(300)
    check('follow: count increments', pg.inner_text('#fcount') != f0, f'{f0}->{pg.inner_text("#fcount")}')
    pg.goto(URL + '?signed#/u/nobody_here'); pg.wait_for_timeout(500)
    check('profile: unknown user shows not-found state', 'غير موجود' in pg.inner_text('#pf'))
    check('profile/settings: no JS errors', not pg._errs, '; '.join(pg._errs))

    # ---------- SEARCH / FILTER / NOTIFICATIONS ----------
    pg = page(h='#/c/Hematology')
    cats = pg.evaluate("[...document.querySelectorAll('.post .chip')].map(c=>c.textContent.trim())")
    check('specialty filter: only matching category shown', cats and all('أمراض الدم' in c for c in cats), str(cats))
    pg.goto(URL + '?signed#/explore'); pg.wait_for_timeout(600)
    check('explore: people list + gallery render', pg.locator('#people .row').count() >= 1 and pg.locator('#gal .tile').count() >= 1)
    pg.fill('#q', 'sara'); pg.wait_for_timeout(500)
    check('search: input wired to query (server-side filter not exercised by mock)', '#people' and pg.evaluate("__CALLS.filter(c=>c=='lg_profiles:select').length") >= 2)
    pg.goto(URL + '?signed#/notifications'); pg.wait_for_timeout(700)
    check('notifications: list renders', pg.locator('#nl .notif').count() >= 1)
    check('notifications: marked read after viewing', pg.evaluate("__DB.lg_notifications.every(n=>n.read)"))
    check('search/notifications: no JS errors', not pg._errs, '; '.join(pg._errs))

    # ---------- ADMIN ----------
    pg = page(h='#/admin/users')
    uid = pg.evaluate("__DB.lg_profiles[2].id")
    pg.click(f'button:has-text("رفع الإيقاف")'); pg.wait_for_timeout(300)
    check('admin: unban user', pg.evaluate(f"__DB.lg_profiles.find(p=>p.id=='{uid}').banned") is False)
    pg.click('#ul .adm-row >> nth=0 >> button:has-text("توثيق")'); pg.wait_for_timeout(300)
    check('admin: verify user', pg.evaluate("__DB.lg_profiles.filter(p=>p.verified).length") >= 2)
    pg.goto(URL + '?signed#/admin/posts'); pg.wait_for_timeout(600)
    pg.locator('#adm .adm-row button', has_text='تثبيت').filter(has_not_text='إلغاء').first.click(); pg.wait_for_timeout(400)
    check('admin: pin post', pg.evaluate("__DB.lg_posts.filter(p=>p.pinned).length") == 2)
    pg.goto(URL + '?signed#/admin/reports'); pg.wait_for_timeout(600)
    pg.click('button:has-text("تجاهل")'); pg.wait_for_timeout(400)
    check('admin: dismiss report', pg.evaluate("__DB.lg_reports.every(r=>r.status=='resolved')"))
    check('admin: no JS errors', not pg._errs, '; '.join(pg._errs))

    # ---------- NAV / LOGOUT ----------
    pg = page()
    bad = []
    for href in ['#/', '#/following', '#/explore', '#/notifications', '#/u/mam87', '#/settings', '#/admin', '#/new', '#/c/Cytology', '#/p/does-not-exist', '#/unknown-route']:
        pg.evaluate(f"location.hash='{href}'"); pg.wait_for_timeout(450)
        if not pg.locator('#main').count(): bad.append(href)
    check('navigation: every route renders the app shell (incl. unknown)', not bad, str(bad))
    pg.evaluate("location.hash='#/settings'"); pg.wait_for_timeout(400)
    pg.click('button:has-text("تسجيل الخروج")'); pg.wait_for_timeout(500)
    check('logout: returns to login screen', pg.locator('#fEmail').count() == 1)
    check('nav/logout: no JS errors', not pg._errs, '; '.join(pg._errs))

    # ---------- EMPTY / ERROR STATES ----------
    pg = page('?signed&empty', '#/')
    check('empty state: feed shows empty message', 'لا توجد منشورات' in pg.inner_text('#feed'))
    pg.evaluate("location.hash='#/notifications'"); pg.wait_for_timeout(500)
    check('empty state: notifications', 'لا توجد تنبيهات' in pg.inner_text('#nl'))
    pg = page('?signed&err=lg_posts', '#/')
    check('error state: failed post load shows toast, no crash', 'تعذّر' in pg.evaluate("document.getElementById('toast').textContent") and not pg._errs, pg.evaluate("document.getElementById('toast').textContent"))
    pg = page('?signed&setup', '#/')
    check('setup state: missing tables shows setup guide', 'schema.sql' in pg.inner_text('#root'))

    # ---------- MOBILE ----------
    pg = page(vp=(375, 740))
    ow = pg.evaluate('document.documentElement.scrollWidth')
    check('mobile 375px: no horizontal overflow', ow <= 375, f'scrollWidth={ow}')
    check('mobile: bottom nav visible, sidebar hidden', pg.locator('.bottom').is_visible() and not pg.locator('.side').is_visible())
    for h in ['#/admin/users', '#/settings', '#/u/mam87', '#/explore']:
        pg.evaluate(f"location.hash='{h}'"); pg.wait_for_timeout(500)
        w = pg.evaluate('document.documentElement.scrollWidth')
        check(f'mobile 375px: no overflow on {h}', w <= 375, f'scrollWidth={w}')
    small = pg.evaluate("[...document.querySelectorAll('.bottom a, .icon-btn, .btn')].filter(e=>e.offsetParent&&(e.offsetHeight<36)).length")
    check('mobile: tap targets >= 36px', small == 0, f'{small} small targets')

    # ---------- RTL / LTR ----------
    check('RTL: document dir=rtl lang=ar', pg.evaluate("document.documentElement.dir=='rtl' && document.documentElement.lang=='ar'"))
    has_en = pg.evaluate("/lang.*en|i18n|translate/i.test(document.documentElement.outerHTML.slice(0,3000))")
    check('LTR/English UI: language switch exists', False, 'not implemented — UI is Arabic-only')

    # ---------- PERF (mobile, 4x CPU throttle) ----------
    ctx = b.new_context(viewport={'width': 390, 'height': 844})
    ctx.route('**/vendor/supabase-js-*.js', lambda r: r.fulfill(body=MOCK, content_type='application/javascript'))
    ctx.route('**/fonts.g*/**', lambda r: r.abort()); ctx.route('**/index.html*', strip_sri)
    pg = ctx.new_page(); cdp = ctx.new_cdp_session(pg); cdp.send('Emulation.setCPUThrottlingRate', {'rate': 4})
    t = time.time(); pg.goto(URL + '?signed#/'); pg.wait_for_selector('.post'); dt = (time.time() - t) * 1000
    check('perf: feed interactive < 2500ms on 4x-throttled CPU (mock data, no network latency)', dt < 2500, f'{dt:.0f}ms')
    b.close()

passed = sum(r[1] for r in results)
print(f'\n{passed}/{len(results)} checks passed')
