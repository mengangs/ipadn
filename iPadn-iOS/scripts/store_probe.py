# TEMPORARY (approved by the repo owner): compares public App Store product pages across
# storefronts and languages to fix in-app price matching. Prints short excerpts; removed before merge.
import json, re, urllib.parse, urllib.request
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
def get(url, lang=None):
    headers = {"User-Agent": UA, "Accept": "text/html"}
    if lang: headers["Accept-Language"] = lang
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=25) as r:
            return r.status, r.geturl(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e: return e.code, url, ""
    except Exception as e: return -1, url, repr(e)
def p(*a): print("PROBE:", *a, flush=True)
def iaps(html):
    m = re.search(r'id="serialized-server-data"[^>]*>(.*?)</script>', html, re.S)
    if not m: return None
    try: data = json.loads(m.group(1))
    except Exception as e: return "json error %r" % e
    found = []
    def visit(v):
        if isinstance(v, dict):
            if v.get("$kind") == "Annotation" and isinstance(v.get("items"), list):
                pairs = [i for i in v["items"] if isinstance(i, dict) and i.get("$kind") == "textPair"]
                if pairs: found.append((v.get("title"), [(i.get("leadingText"), i.get("trailingText")) for i in pairs][:12]))
            for c in v.values(): visit(c)
        elif isinstance(v, list):
            for c in v: visit(c)
    visit(data)
    return found
ids = []
for term in ["EplayerX", "Infuse"]:
    _, _, body = get("https://itunes.apple.com/search?" + urllib.parse.urlencode({"term": term, "entity": "software", "country": "us", "limit": 2}))
    try: ids += [str(r["trackId"]) for r in json.loads(body)["results"]][:1]
    except Exception as e: p("search", term, repr(e))
p("ids", ids)
for app in ids:
    for cc in ["us", "jp", "kr", "tr", "ng", "hk", "cn"]:
        for lang, suffix in [("zh-Hans-CN,zh-Hans;q=0.9", ""), (None, "?l=en-US"), ("zh-Hans-CN,zh-Hans;q=0.9", "?l=en-US")]:
            status, final, html = get(f"https://apps.apple.com/{cc}/app/id{app}{suffix}", lang)
            r = iaps(html) if status == 200 else None
            p(app, cc, lang or "-", suffix or "-", status, final[-60:], len(html), json.dumps(r, ensure_ascii=False)[:700] if r is not None else "no data")
