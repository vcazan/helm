import math
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGB", (S, S), (10, 10, 11))
g = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(g)
for r in range(700, 0, -4):
    d.ellipse([S/2-r, S*0.42-r, S/2+r, S*0.42+r], fill=int(38 * (1 - r/700)))
img = Image.composite(Image.new("RGB", (S, S), (60, 58, 52)), img, g)
layer = Image.new("RGBA", (S*2, S*2), (0, 0, 0, 0))
L = ImageDraw.Draw(layer)
c = S
col = (242, 241, 236, 255)
r = S*0.30*2*0.66
lw = int(S*0.075*2*0.66)
L.ellipse([c-r, c-r, c+r, c+r], outline=col, width=lw)
hub = lw*1.15
L.ellipse([c-hub, c-hub, c+hub, c+hub], fill=col)
for i in range(8):
    a = i*math.pi/4
    x0, y0 = c+math.cos(a)*lw*1.6, c+math.sin(a)*lw*1.6
    x1, y1 = c+math.cos(a)*S*0.47*2*0.66, c+math.sin(a)*S*0.47*2*0.66
    w = int(lw*0.85)
    L.line([x0, y0, x1, y1], fill=col, width=w)
    L.ellipse([x1-w/2, y1-w/2, x1+w/2, y1+w/2], fill=col)
layer = layer.resize((S, S), Image.LANCZOS)
glow = layer.filter(ImageFilter.GaussianBlur(28))
img.paste((255, 250, 235), (0, 0), glow.split()[3].point(lambda v: int(v*0.18)))
img.paste(layer, (0, 0), layer)
img.save("Helm/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
