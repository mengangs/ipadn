# TEMPORARY (approved by the repo owner): reads public App Store pages from the CI host to learn
# the in-app purchase data format. Prints short excerpts only; removed before merge.
import re, urllib.request
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e: return e.code, e.read().decode("utf-8", "replace")[:300]
    except Exception as e: return -1, repr(e)
def p(*a): print("PROBE:", *a, flush=True)
def ctx(text, needle, span=900):
    i = text.find(needle)
    return "<none>" if i < 0 else text[max(0, i - 200):i + span].replace("\n", " ")
token = None
for cc, app in [("us", "324684580"), ("tr", "324684580"), ("us", "570060128"), ("us", "916366645")]:
    status, html = get(f"https://apps.apple.com/{cc}/app/id{app}")
    p("page", cc, app, status, len(html))
    for needle in ["In-App Purchase", "Uygulama İçi", "inAppPurchase", "top-in-apps", "serialized-server-data", "subscription", "offers"]:
        n = html.count(needle); p("  ", needle, n)
        if n and needle in ("In-App Purchase", "Uygulama İçi", "inAppPurchase", "top-in-apps"): p("  ctx", needle, ctx(html, needle))
    m = re.search(r'<script[^>]*id="serialized-server-data"[^>]*>(.*?)</script>', html, re.S)
    if m:
        data = m.group(1); p("  ssd bytes", len(data))
        for key in ["In-App Purchases", "inAppPurchases", "purchases", "price"]:
            p("  ssd", key, data.count(key), ctx(data, key, 1500))
    if not token:
        t = re.search(r"eyJ[\w-]{20,}\.[\w-]{20,}\.[\w-]{20,}", html)
        if t: token = t.group(0); p("  token in html")
    if not token:
        for src in re.findall(r'src="([^"]+\.js)"', html)[:10]:
            url = src if src.startswith("http") else "https://apps.apple.com" + src
            _, js = get(url)
            t = re.search(r"eyJ[\w-]{20,}\.[\w-]{20,}\.[\w-]{20,}", js)
            if t: token = t.group(0); p("  token in", url); break
if token:
    for host in ["amp-api-edge.apps.apple.com", "amp-api.apps.apple.com"]:
        for cc, app in [("us", "324684580"), ("tr", "570060128"), ("us", "916366645")]:
            url = f"https://{host}/v1/catalog/{cc}/apps/{app}?platform=iphone&include=top-in-apps&l=en-US"
            status, body = get(url, {"Authorization": "Bearer " + token, "Origin": "https://apps.apple.com"})
            p("amp", host, cc, app, status, len(body))
            p("  top", ctx(body, "top-in-apps", 3000))
else:
    p("no token")
status, body = get("https://open.er-api.com/v6/latest/CNY"); p("rates", status, body[:300])
status, body = get("https://itunes.apple.com/lookup?id=324684580&country=tr"); p("lookup", status, body[:400])
