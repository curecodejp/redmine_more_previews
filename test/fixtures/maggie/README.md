# Maggie test images

Small images made for `test/unit/maggie_command_test.rb`. In each, the stored
image is 32x16, red on the left and blue on the right, unless noted.

| File | Content |
|---|---|
| `plain.heic` | HEIC, brands `heic` / `mif1 heic miaf` |
| `plain.heif` | `plain.heic` with the major brand `mif1` |
| `rotated.heic` | `irot` 270 (anticlockwise) and EXIF orientation 6, as an iPhone writes them: shown 16x32, red on top |
| `multi.heic` | two images: a green 16x16 one first, then the primary one (`pitm` 2) |
| `multipage.tif` | two pages: the first as above, then a green 8x8 one |
| `rotated.tif` | orientation 6 (RightTop): shown 16x32, red on top |
| `cmyk.tif` | 8x8 red in CMYK |

## How they were made

HEIC with [pillow-heif](https://github.com/bigcat88/pillow_heif) 1.1.1 (libheif 1.20.2, x265),
which writes EXIF orientation 6 as `irot` 270 and keeps the EXIF:

```python
import pillow_heif
from PIL import Image

def halves(w, h, a, b):
    im = Image.new('RGB', (w, h), a)
    im.paste(Image.new('RGB', (w // 2, h), b), (w // 2, 0))
    return im

halves(32, 16, (255, 0, 0), (0, 0, 255)).save('plain.heic', quality=90)

im = halves(32, 16, (255, 0, 0), (0, 0, 255))
exif = im.getexif()
exif[0x0112] = 6
im.save('rotated.heic', quality=90, exif=exif.tobytes())

heif = pillow_heif.from_pillow(Image.new('RGB', (16, 16), (0, 255, 0)))
heif.add_from_pillow(halves(32, 16, (255, 0, 0), (0, 0, 255)))
heif.save('multi.heic', quality=90)
```

pillow-heif makes the first image the primary one, so `multi.heic` was patched to
make the second one primary (`pitm` item 1 → 2), and `plain.heif` is `plain.heic`
with its major brand (bytes 8 - 11) `heic` → `mif1`.

TIFF with ImageMagick 6.9.13:

```sh
convert \( -size 16x16 xc:red -size 16x16 xc:blue +append \) \( -size 8x8 xc:lime \) -compress zip multipage.tif
convert -size 16x16 xc:red -size 16x16 xc:blue +append -orient RightTop -compress zip rotated.tif
convert -size 8x8 xc:red -colorspace CMYK -compress zip cmyk.tif
```
