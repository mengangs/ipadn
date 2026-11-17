from PIL import Image, ImageDraw
import json, math, pathlib

def flatten(points, closed, steps=12):
    pts = [(points[0], points[1])]
    i = 2
    while i + 5 < len(points):
        c1 = (points[i], points[i+1]); c2 = (points[i+2], points[i+3]); e = (points[i+4], points[i+5])
        p0 = pts[-1]
        for s in range(1, steps+1):
            t = s/steps; mt = 1-t
            x = mt**3*p0[0] + 3*mt*mt*t*c1[0] + 3*mt*t*t*c2[0] + t**3*e[0]
            y = mt**3*p0[1] + 3*mt*mt*t*c1[1] + 3*mt*t*t*c2[1] + t**3*e[1]
            pts.append((x, y))
        i += 6
    if closed and len(pts) > 2:
        pts.append(pts[0])
    return pts

def render(path, scale=6, frame=-1):
    a = json.load(open(path, encoding="utf-8"))
    size = int(a["canvas"][0]*scale)
    img = Image.new("RGBA", (size, size), (255,255,255,255))
    d = ImageDraw.Draw(img)
    for t in a["tracks"]:
        f = t["frames"][frame]
        for c in f["contours"]:
            pts = [(x*scale, y*scale) for x, y in flatten(c["points"], c["closed"])]
            if t["stroke"]:
                d.line(pts, fill=(0,0,0,255), width=max(1,int(f["width"]*scale)), joint="curve")
            else:
                d.polygon(pts, fill=(0,0,0,255) if f["opacity"] > .5 else None)
    return img, a["tracks"]

names = ["tab_search", "tab_downloads", "tab_packages", "tab_purchased", "tab_account"]
imgs = []
for n in names:
    img, _ = render(f"iPadn-iOS/iPadn/Resources/RevealAnimations/{n}.json", scale=6)
    imgs.append(img)
strip = Image.new("RGBA", (sum(i.width for i in imgs) + 20*len(imgs), imgs[0].height), (255,255,255,255))
x = 0
for i in imgs:
    strip.paste(i, (x, 0)); x += i.width + 20
strip.save("artifacts/icon-compare.png")
print("wrote artifacts/icon-compare.png", strip.size)

# animation frames for the packages icon
frames = []
for idx in [0, 6, 10, 16, 22, 30]:
    img, _ = render("iPadn-iOS/iPadn/Resources/RevealAnimations/tab_packages.json", scale=6, frame=idx)
    frames.append(img)
strip2 = Image.new("RGBA", (sum(i.width for i in frames) + 12*len(frames), frames[0].height), (255,255,255,255))
x = 0
for i in frames:
    strip2.paste(i, (x, 0)); x += i.width + 12
strip2.save("artifacts/icon-anim-frames.png")
print("wrote artifacts/icon-anim-frames.png", strip2.size)
