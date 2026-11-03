from PIL import Image
src = r"C:\Users\GREAT\.dsh\attachments\v1\objects\4c\4c9b1bf7db7a2a7a8f2c8a9d34398dbaf09523061b11083764b522643a31a961"
im = Image.open(src).convert("RGB")
print("size", im.size)
# crop the "Face" text area and the bottle
w, h = im.size
# monitor content occupies roughly x 60..1520, y 100..1000 in the 1512-wide preview; scale
sx = w / 1512.0; sy = h / 1134.0
def crop(x0, y0, x1, y1, name, zoom=3):
    box = (int(x0*sx), int(y0*sy), int(x1*sx), int(y1*sy))
    c = im.crop(box)
    c = c.resize((c.width*zoom, c.height*zoom), Image.NEAREST)
    out = r"C:\Users\GREAT\Desktop\camara_helper_0\tools\_crop_%s.png" % name
    c.save(out)
    print(name, box, "->", out)
crop(430, 400, 700, 560, "face", 3)
crop(950, 700, 1150, 900, "floor", 3)
crop(60, 120, 300, 300, "topleft", 3)
