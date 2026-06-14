package tray

import (
	"bytes"
	"image"
	"image/draw"
	"image/png"
)

// trayMarginRatio gives breathing room around the content, as a fraction of its
// longest side (1/10 = 10% on each side).
const trayMarginRatio = 10

// processIcon trims the asymmetric transparent padding from the source PNG and
// re-centers the artwork in a square canvas at full resolution. macOS then
// scales the large image down to the menu-bar height so it lines up with the
// native icons next to it. On any failure it returns the original bytes.
func processIcon(src []byte) []byte {
	img, err := png.Decode(bytes.NewReader(src))
	if err != nil {
		return src
	}

	rgba := image.NewRGBA(img.Bounds())
	draw.Draw(rgba, rgba.Bounds(), img, img.Bounds().Min, draw.Src)

	sw := rgba.Bounds().Dx()
	sh := rgba.Bounds().Dy()

	// Bounding box of non-transparent content.
	x0, y0, x1, y1 := sw, sh, 0, 0
	found := false
	for y := 0; y < sh; y++ {
		for x := 0; x < sw; x++ {
			if rgba.RGBAAt(x, y).A > 16 {
				found = true
				if x < x0 {
					x0 = x
				}
				if y < y0 {
					y0 = y
				}
				if x > x1 {
					x1 = x
				}
				if y > y1 {
					y1 = y
				}
			}
		}
	}
	if !found {
		return src // fully transparent — nothing to trim
	}

	contentW := x1 - x0 + 1
	contentH := y1 - y0 + 1

	longest := contentW
	if contentH > longest {
		longest = contentH
	}
	side := longest + 2*(longest/trayMarginRatio)
	offX := (side - contentW) / 2
	offY := (side - contentH) / 2

	dst := image.NewRGBA(image.Rect(0, 0, side, side))
	srcRect := image.Rect(x0, y0, x1+1, y1+1)
	draw.Draw(dst, image.Rect(offX, offY, offX+contentW, offY+contentH), rgba, srcRect.Min, draw.Src)

	var buf bytes.Buffer
	if err := png.Encode(&buf, dst); err != nil {
		return src
	}
	return buf.Bytes()
}
