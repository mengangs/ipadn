"""Read-only vector QA renderer: winding holes, tint opacity, round caps."""
import json
from pathlib import Path
from PIL import Image,ImageDraw,ImageChops

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/uiux'
OUT.mkdir(parents=True,exist_ok=True)

def points(c,s):
    p=c['points']; result=[(p[0]*s,p[1]*s)]
    for i in range(2,len(p),6):
        x,y=result[-1]; c1x,c1y,c2x,c2y,ex,ey=[v*s for v in p[i:i+6]]
        for n in range(1,17):
            t=n/16; u=1-t
            result.append((u**3*x+3*u*u*t*c1x+3*u*t*t*c2x+t**3*ex,u**3*y+3*u*u*t*c1y+3*u*t*t*c2y+t**3*ey))
    if c['closed']:result.append(result[0])
    return result

def render(name,index=-1,size=180,dark=False):
    asset=json.loads((ROOT/f'iPadn-iOS/iPadn/Resources/RevealAnimations/{name}.json').read_text())
    scale=8
    image=Image.new('RGBA',(416,416),(18,18,18,255) if dark else (255,255,255,255))
    color=(255,255,255) if dark else (0,0,0)
    for tr in asset['tracks']:
        f=tr['frames'][index]; layer=Image.new('RGBA',image.size,(*color,0)); draw=ImageDraw.Draw(layer)
        mask=Image.new('1',image.size)
        for c in f['contours']:
            pts=points(c,scale)
            if tr['stroke']:
                width=round(f['width']*scale); opacity=round(f['opacity']*255)
                draw.line(pts,fill=(*color,opacity),width=width,joint='curve')
                if not c['closed']:
                    for x,y in [pts[0],pts[-1]]:draw.ellipse((x-width/2,y-width/2,x+width/2,y+width/2),fill=(*color,opacity))
            else:
                part=Image.new('1',image.size); ImageDraw.Draw(part).polygon(pts,fill=1)
                mask=ImageChops.logical_xor(mask,part)
        if not tr['stroke']:layer.putalpha(mask.convert('L').point(lambda v:round(v*f['opacity'])))
        image=Image.alpha_composite(image,layer)
    return image.resize((size,size),Image.Resampling.LANCZOS)

names=['tab_search','tab_downloads','tab_packages','tab_purchased','tab_account']
strip=Image.new('RGBA',(5*180,360),'white')
for y,dark in [(0,False),(180,True)]:
    for i,name in enumerate(names):strip.paste(render(name,dark=dark),(i*180,y))
strip.save(OUT/'carton-icons.png')
pkg=json.loads((ROOT/'iPadn-iOS/iPadn/Resources/RevealAnimations/tab_packages.json').read_text())
frame_count=len(pkg['tracks'][0]['frames'])
indices=[round(k*(frame_count-1)/8) for k in range(9)]
strip=Image.new('RGBA',(len(indices)*180,180),'white')
for i,n in enumerate(indices):strip.paste(render('tab_packages',n),(i*180,0))
strip.save(OUT/'carton-frames.png')
frames=[render('tab_packages',n,size=156) for n in range(frame_count)]
frames[0].save(OUT/'carton-animation.gif',save_all=True,append_images=frames[1:],duration=max(8,round(1000*pkg['duration']/max(1,frame_count-1))),loop=0)
print('Rendered five-tab comparison, carton storyboard and motion preview')
