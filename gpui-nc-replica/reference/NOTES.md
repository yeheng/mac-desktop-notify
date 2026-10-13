# macOS Notification Center / Banner reference notes

Sources: support.apple.com, iDownloadBlog (Big Sur), groovyPost (Big Sur),
MakeUseOf (Big Sur), Cultured Code/Things (Big Sur), The Verge (Ventura).
All light-mode appearance; no clean dark-mode panel screenshot could be found
in public articles (banners/NC in dark mode are translucent dark — see
banner-in-context-ventura.webp for the closest example).

## nc-panel-stacks-light.jpg (700x1477, iDownloadBlog, Big Sur)
Full NC column crop. Card inset from panel edge ~3% of column width each side
(~22px of 700px crop; column is ~350pt at 2x, so cards ~324pt wide, ~10pt inset).
Stacked group: 2 extra layers peek below the top card, each ~6px(3pt) lower and
~4px(2pt) narrower per side. Card corner radius ~25-30px in crop (~13pt, ~4% of
card width). "7 more notifications" centered pill between notifications and
widgets. Widgets: 2-column grid, gap between columns ~15px (~7-8pt), widget
corner radius similar to cards. App header row: small square icon + APP NAME in
gray caps left, relative time right ("23m ago", "Yesterday, 07:57 PM").

## nc-panel-on-desktop-light.png (825x413, MakeUseOf, Big Sur)
Whole desktop with NC open (widgets-only). Panel width ~215/825 ≈ 26% of screen
width. Panel starts directly below the menu bar (menu bar ~3.4% of screen
height) and runs to screen bottom. Right screen edge gap ≈ 2.4% of screen width.
"Edit Widgets" pill centered at panel bottom. Two-column widget grid; small
widgets are square, medium are 2x-width rectangles.

## nc-grouped-stacks-light.png (1662x928 @2x, groovyPost, Big Sur)
Close-up of 6 stacked groups. Stack peek: layers visible as ~12px and ~22px
(≈6pt/11pt) slivers under the top card. "N more notifications" gray text at
bottom-left inside the top card. Body text up to 2 lines, truncated. Card corner
radius ~22px (~11pt) against ~765px (~382pt) card width.

## banner-hover-states-light.jpg (2488x958 @2x, groovyPost, Big Sur)
Multiple NC cards/banners. Hover close button: circled × appears at the TOP-LEFT
corner, straddling the card edge. Chevron › at top-right expands detail.
"Options ▾" pill at bottom-right when expanded; context menu (Reply / Mark as
read / Delete) drops below it. "now" timestamp top-right. Content thumbnails
(square, rounded) appear right-aligned inside cards. Banners stack vertically
with ~10px(5pt) gaps along the right edge.

## banner-options-menu-light.jpg (876x461, Cultured Code, Big Sur)
Single banner below menu bar. Menu bar ≈ 45/461 ≈ 10% of frame height; gap from
menu bar to banner top ≈ 40px ≈ 8.7%. Banner ≈ 695x130px (≈ 348x65pt) with
corner radius ~25px (~12pt, ~19% of banner height). Circled × hover button
diameter ~40px (~20pt), centered on the top-left corner. "Options ▾" pill
bottom-right opens a menu with row height ~55px (~27pt), selected row filled
accent blue.

## banner-in-context-ventura.webp (1161x774, The Verge, Ventura)
Banner floating over desktop wallpaper, top-right, sliding in (right edge at
screen edge). Banner top gap below menu bar ≈ 32px ≈ 4% of screen height;
banner height ≈ 120px ≈ 15.5% of screen height; corner radius ~25px ≈ 20% of
banner height. App icon (rounded square avatar) left, bold title + 1-line body.
(16KB WebP — below the 30KB filter threshold but verified genuine; kept as the
only in-context banner shot.)

## nc-widgets-apple-official.png (1116x1354, support.apple.com, Sonoma-era)
Apple official render of the NC column: large Calendar widget on top, small
Clock widget, medium Photos widget, "Edit Widgets" pill + circled × at the very
bottom. Large-widget corner radius ≈ 55px on ~490px width (≈ 11%); small square
widget radius ≈ 45px on ~220px (≈ 20%). Widget grid gap ≈ 40px between rows.
Left screen bezel area shows the NC panel is a flush right-edge column whose
content (widgets) floats over the blurred desktop.
