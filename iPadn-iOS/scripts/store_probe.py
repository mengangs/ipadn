# TEMPORARY (approved by the repo owner): finds where public App Store product pages keep the
# version history with release notes. Prints short excerpts only; removed before merge.
import json, re, urllib.request
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
def get(url, lang="en-US"):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html", "Accept-Language": lang})
        with urllib.request.urlopen(req, timeout=25) as r: return r.status, r.geturl(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e: return e.code, url, ""
    except Exception as e: return -1, url, repr(e)
def p(*a): print("PROBE:", *a, flush=True)
def data(html):
    m = re.search(r'id="serialized-server-data"[^>]*>(.*?)</script>', html, re.S)
    try: return json.loads(m.group(1)) if m else None
    except Exception: return None
def walk(v, path, out):
    if isinstance(v, dict):
        keys = set(v.keys())
        if any(k.lower() in ("releasenotes", "versiondisplay", "versionhistory", "releasedate", "versionstring") for k in keys):
            out.append((path, json.dumps(v, ensure_ascii=False)[:500]))
        for k, c in v.items(): walk(c, path + "/" + k, out)
    elif isinstance(v, list):
        for i, c in enumerate(v[:60]): walk(c, path + "[%d]" % i, out)
for app in ["1136220934", "6448311069"]:
    for url in [f"https://apps.apple.com/us/app/id{app}?l=en-US",
                f"https://apps.apple.com/us/app/id{app}?see-all=version-history",
                f"https://apps.apple.com/us/app/id{app}/version-history",
                f"https://apps.apple.com/cn/app/id{app}?l=zh-Hans-CN"]:
        status, final, html = get(url)
        d = data(html) if status == 200 else None
        out = []
        if d is not None: walk(d, "", out)
        p(app, url[-50:], status, final[-50:], len(html), "matches", len(out))
        for path, snippet in out[:6]: p("   ", path[-90:], snippet)
        for needle in ["Version History", "版本历史记录", "releaseNotes", "versionHistory"]:
            i = html.find(needle)
            if i >= 0: p("   ctx", needle, html.count(needle), html[max(0, i-150):i+350].replace("\n", " "))
