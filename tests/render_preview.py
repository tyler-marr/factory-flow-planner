import json, base64, zlib, sys, re
import lupa.lua52 as L
from PIL import Image, ImageDraw, ImageFont
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import make_runtime
lua = make_runtime()
lua.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'preview.lua')).read())
g = lua.globals()
objs = [g.OBJECTS[i] for i in range(1, len(g.OBJECTS)+1)]
ox, oy = g.ORIGIN.x, g.ORIGIN.y
T = 30  # px per tile
X0, Y0, W, Hh = -24, -4, 84, 20
img = Image.new("RGB", (W*T, Hh*T), (28,28,30)); d = ImageDraw.Draw(img, "RGBA")
fr = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"; fb = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
def P(t):
    return ((t.x - ox - X0)*T, (t.y - oy - Y0)*T)
def col(c):
    v=[c[i] if c[i] is not None else 1 for i in range(1, 5) if c[i] is not None] if c[1] is not None else [c.r or 0, c.g or 0, c.b or 0, c.a if c.a is not None else 1]
    if len(v)==3: v.append(1)
    return tuple(int(x*255) for x in v)
def flat(t):
    if L.lua_type(t) == 'table':
        items=[t[i] for i in range(1, len(t)+1)]
        if items and isinstance(items[0], str) and items[0].startswith(('item-name.','fluid-name.','recipe-name.','entity-name.')):
            return items[0].split('.',1)[1].replace('-',' ').capitalize()
        if items and items[0] == "": return "".join(flat(x) for x in items[1:])
        return "".join(flat(x) for x in items)
    return str(t)
def clean(s):
    s = re.sub(r'\[color=[^\]]*\]|\[/color\]|\[font=[^\]]*\]|\[/font\]', '', s)
    return s
ground = [o for o in objs if o.args.draw_on_ground]
top = [o for o in objs if not o.args.draw_on_ground]
def draw(o):
    a = o.args
    if o.kind == 'rectangle':
        x1,y1 = P(a.left_top); x2,y2 = P(a.right_bottom)
        if a.filled: d.rectangle([x1,y1,x2,y2], fill=col(a.color))
        else: d.rectangle([x1,y1,x2,y2], outline=col(a.color), width=max(1,int((a.width or 1))))
    elif o.kind == 'line':
        d.line([P(a['from']), P(a.to)], fill=col(a.color), width=int(a.width or 1))
    elif o.kind == 'circle':
        x,y = P(a.target); r=a.radius*T
        d.ellipse([x-r,y-r,x+r,y+r], fill=col(a.color))
    elif o.kind == 'sprite':
        x,y = P(a.target); s=(a.x_scale or 1)*2*T*0.5
        d.rectangle([x-s/2,y-s/2,x+s/2,y+s/2], fill=(120,150,190,255)); 
    elif o.kind == 'text':
        x,y = P(a.target); sc = a.scale or 1
        f = ImageFont.truetype(fb if a.font and 'bold' in a.font else fr, int(14*sc*T/32))
        s = clean(flat(a.text))
        parts = re.split(r'(\[(?:item|fluid|entity|recipe|img)=[^\]]*\])', s)
        # measure
        widths=[]; 
        for p in parts:
            widths.append(int(f.size*1.1) if p.startswith('[') else d.textlength(p, font=f))
        tw=sum(widths)
        al = a.alignment or 'left'
        cx = x - (tw/2 if al=='center' else tw if al=='right' else 0)
        cy = y - f.size*0.6
        for p,wd in zip(parts,widths):
            if p.startswith('['):
                d.rectangle([cx+1, cy+2, cx+wd-2, cy+f.size+1], fill=(120,150,190,255))
            else:
                d.text((cx,cy), p, font=f, fill=col(a.color))
            cx += wd
# As observed in game (0.1.0): sprites sit in a lower layer than script
# shapes and text, which draw in creation order.
for o in ground: draw(o)
# Belt and pipe entities (drawn above ground-layer shapes, as in game).
BELT = {"transport-belt": (220,180,40), "fast-transport-belt": (210,60,50), "express-transport-belt": (60,140,230)}
ents = [g.ENTS[i] for i in range(1, len(g.ENTS)+1)]
for e in ents:
    cx, cy = (e.position.x - ox - X0)*T, (e.position.y - oy - Y0)*T
    x1,y1,x2,y2 = cx-T/2, cy-T/2, cx+T/2, cy+T/2
    n = e.name
    if n in ("pipe", "pipe-to-ground"):
        d.rectangle([x1+T*0.25,y1+T*0.25,x2-T*0.25,y2-T*0.25], fill=(150,150,155))
        d.rectangle([x1+T*0.38,y1+T*0.05,x2-T*0.38,y2-T*0.05], fill=(150,150,155)) if False else None
        if n == "pipe-to-ground": d.ellipse([x1+4,y1+4,x2-4,y2-4], outline=(60,60,60), width=3)
    else:
        base = n.replace("underground-belt","transport-belt") if "underground" in n else n
        c = BELT.get(base, (200,200,200))
        d.rectangle([x1+1,y1+1,x2-1,y2-1], fill=tuple(int(v*0.55) for v in c))
        dirn = {0:(0,-1),4:(1,0),8:(0,1),12:(-1,0)}[e.direction]
        tip = (cx+dirn[0]*T*0.35, cy+dirn[1]*T*0.35)
        left = (cx-dirn[0]*T*0.2-dirn[1]*T*0.25, cy-dirn[1]*T*0.2+dirn[0]*T*0.25)
        right = (cx-dirn[0]*T*0.2+dirn[1]*T*0.25, cy-dirn[1]*T*0.2-dirn[0]*T*0.25)
        d.polygon([tip,left,right], fill=c)
        if "underground" in n: d.rectangle([x1+1,y1+1,x2-1,y2-1], outline=(20,20,20), width=3)
for o in [o for o in top if o.kind=='sprite']: draw(o)
for o in [o for o in top if o.kind!='sprite']: draw(o)
out = sys.argv[1] if len(sys.argv) > 1 else 'preview.png'
img.save(out)
print("saved", out, "with", len(objs), "drawing calls")
