# pitcrew logo

A pit board, held out to the driver: a checkered strip and `›_ GO!`. Every
letter is a stroke, so the files render the same without any fonts.

| File | Use |
| --- | --- |
| `pitcrew-mark.svg` | The board on its stand, square |
| `pitcrew-lockup-light.svg`, `pitcrew-lockup-dark.svg` | Board and wordmark, for light or dark backgrounds |
| `pitcrew-wordmark-light.svg`, `pitcrew-wordmark-dark.svg` | The wordmark alone |
| `pitcrew-favicon.svg` | A simplified board for 16 to 64 px: checkered strip and `›_` |
| `png/app-logo-1024.png` | Square app logo on a dark tile, safe for a circular crop |
| `png/mark-transparent-1024.png` | The board alone, transparent |
| `png/social-preview-dark.png`, `png/social-preview-light.png` | Repository social preview, 1280×640 |
| `png/apple-touch-icon-180.png`, `png/favicon-32.png` | Icons for web pages |

Colors: board `#FFB224`, ink `#1A1A1A`, stand `#8A8F98`, wordmark `#17181A`
on light and `#ECECEE` on dark.

Regenerate the PNGs with `rsvg-convert`, for example
`rsvg-convert -w 1024 -h 1024 pitcrew-mark.svg -o png/mark-transparent-1024.png`.
