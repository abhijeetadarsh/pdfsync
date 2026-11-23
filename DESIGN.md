---
name: PDF Sync
description: A precise personal reading workspace with a compact library and a paper-first reader.
colors:
  dark-primary: "#CBA6F7"
  dark-on-primary: "#11111B"
  dark-primary-container: "#313244"
  dark-on-primary-container: "#CBA6F7"
  dark-surface: "#11111B"
  dark-surface-container: "#181825"
  dark-surface-container-high: "#1E1E2E"
  dark-surface-container-highest: "#313244"
  dark-on-surface: "#CDD6F4"
  dark-on-surface-variant: "#A6ADC8"
  dark-outline: "#585B70"
  dark-outline-variant: "#313244"
  dark-tertiary: "#F9E2AF"
  light-primary: "#7041A0"
  light-on-primary: "#FFFFFF"
  light-primary-container: "#E8DCF4"
  light-on-primary-container: "#542677"
  light-surface: "#F8F7FC"
  light-surface-container: "#F0EDF6"
  light-surface-container-high: "#EAE5F1"
  light-surface-container-highest: "#DED8E8"
  light-on-surface: "#292436"
  light-on-surface-variant: "#625A72"
  light-outline: "#81778E"
  light-outline-variant: "#D5CEDF"
  light-tertiary: "#785619"
  annotation-green: "#A6E3A1"
  annotation-yellow: "#F9E2AF"
  annotation-blue: "#74C7EC"
  annotation-pink: "#F5C2E7"
typography:
  headline:
    fontFamily: JetBrainsMono
    fontSize: "26px"
    fontWeight: 700
    lineHeight: 1.25
  title:
    fontFamily: JetBrainsMono
    fontSize: "22px"
    fontWeight: 700
  section-title:
    fontFamily: JetBrainsMono
    fontSize: "14px"
    fontWeight: 700
  body:
    fontFamily: JetBrainsMono
    fontSize: "13px"
    lineHeight: 1.5
  caption:
    fontFamily: JetBrainsMono
    fontSize: "11px"
    lineHeight: 1.5
  label:
    fontFamily: JetBrainsMono
    fontSize: "13px"
    fontWeight: 700
rounded:
  square: "0px"
spacing:
  step-4: "4px"
  step-8: "8px"
  step-12: "12px"
  step-14: "14px"
  step-16: "16px"
  step-20: "20px"
  step-24: "24px"
  step-28: "28px"
  step-32: "32px"
  step-48: "48px"
components:
  button-primary:
    backgroundColor: "{colors.dark-primary}"
    textColor: "{colors.dark-on-primary}"
    rounded: "{rounded.square}"
    typography: "{typography.label}"
  button-primary-light:
    backgroundColor: "{colors.light-primary}"
    textColor: "{colors.light-on-primary}"
    rounded: "{rounded.square}"
    typography: "{typography.label}"
  input:
    backgroundColor: "{colors.dark-surface-container}"
    textColor: "{colors.dark-on-surface}"
    rounded: "{rounded.square}"
    padding: "16px 14px"
---
# Design System: PDF Sync

## Overview

**Creative North Star: "A precise personal reading workspace"**

A precise personal reading workspace, with a compact library and a paper-first reader. Near-black blue surfaces, lavender actions, muted blue text, square controls and bundled monospace type carry the approved ui-design-fixed.html direction into Flutter.

The interface supports personal reading and annotation across devices. Material controls retain their semantic, keyboard, focus, touch and platform behavior; the visual identity is applied through the shared theme rather than replacing those controls with decorative replicas.

**Key Characteristics:**

- Compact, task-led hierarchy
- Dark and light appearances with shared square geometry
- Bundled monospace UI and fine dividers
- Real PDF pages and records rather than showcase fixtures

## Colors

The frontmatter records explicit Flutter overrides; dark and light prefixes are appearance variants of the same semantic roles. ColorScheme.fromSeed supplies remaining Material roles, including errors and state behavior; those derived values are not frozen here.

### Primary

Lavender is the dark primary action and selection accent; a deeper violet serves the same role in light mode. On-primary contrasts with filled actions. Primary-container and on-primary-container mark selected tools and navigation without overwhelming document content.

### Tertiary

Warm yellow marks the tertiary role. Annotation green, yellow, blue and pink are utility colors, kept distinct from action hierarchy.

### Neutral

Surface is the reading workspace; surface-container houses chrome, inputs and annotation browsing. High and highest containers distinguish menus, selected filters, progress tracks and status controls. On-surface is main UI text; on-surface-variant is secondary metadata. Outline and outline-variant supply control edges and fine separators.

## Typography

JetBrains Mono is bundled as JetBrainsMono, with Regular and Bold (700) font files and OFL.txt. There is no remote font request. The shared headline, title, section-title, body, caption and label overrides appear in frontmatter; unspecified metrics inherit Material 3 defaults. Intermediate weights requested locally use Flutter's font matching. The mono family applies to UI, not the embedded PDF's typography.

## Layout

Values are Flutter logical pixels; CSS px in the portable token layer represents the corresponding logical measurement. Login scrolls within SafeArea, uses horizontal padding (24), vertical padding (32), and a maximum form width (380).

Library switches at (760): compact has inline account/sync, horizontal reading filters and Add PDF floating action; expanded has a sidebar (224), view controls and header Add PDF. At (1240), the desktop detail pane (288) appears and list becomes the initial view. Intermediate expanded layouts initially use a grid; user view choice overrides that default. Grid cells use maximum cross-axis extent (200), main-axis extent (290), and gaps (20). Main library horizontal padding changes from (20) to (28).

Reader switches independently at (900): expanded tools sit beneath the app bar and annotations can occupy a side panel (320); compact tools sit at the bottom and annotations open in a sheet. The toolbar has an internal (600) packing threshold and horizontal scrolling for constrained widths. Do not replace these distinct layout thresholds with one universal device breakpoint. Viewport width changes are handled once by ResponsivePdfSizing, a custom Legacy-derived sizing delegate: fit-width stays fitted, deliberate zoom retains its ratio to pane width, and the visible page anchor is preserved. It retains the one-pass rendering threshold (4); no delayed resize transform applies a second scale.

## Elevation & Depth

Tonal surfaces and one-pixel dividers provide structural depth. App bar and floating action button explicitly use zero elevation; filled buttons are flat. Dialogs, menus, tooltips and Material interaction overlays retain framework behavior where not overridden. This is not a claim that every framework overlay has zero shadow.

Reader chrome slides with ease-out over (220ms), or instantly when disableAnimations is enabled. The floating page thumb has its own short fade timings; no ornamental motion is required.

## Shapes

Shared buttons, fields, dialogs, menus, sheets, floating action and progress geometry are square. Annotation swatches are rectangular; selected swatches receive a thicker primary outline. The current reader input-mode badge still has a small rounded corner (4), and the page-thumb indicator retains rounded edges. These are implementation exceptions, not a new rounded card vocabulary. Bottom sheets retain Material's drag handle.

## Components

### Buttons

Filled actions use primary/on-primary; outlined and text actions retain Material roles and state layers. Shared button and icon-button minimum size is (48 × 48), with icon size (20). Square geometry applies across variants. Disabled, hover, pressed and focus states remain Material-managed. Do not hard-code replacement CSS state colors into Flutter.

### Cards / Containers

Library rows and grid tiles use document thumbnails, semantic surfaces and fine borders. Continue-reading opens the actual recent record. Expanded desktop selection reveals actual document details. Empty, loading, search-empty and import states are operational UI, not sample content.

### Inputs / Fields

Filled square fields use surface-container and outline-variant; focus changes to primary with a two-pixel border. Login accepts trimmed addresses containing @, including local addresses such as reader@lan, in line with the server contract; password validation remains mode-dependent. It supports autofill and password visibility, disables submission while busy, and announces errors with a live region. Server URL changes in a validated dialog.

### Navigation

Library filters count actual reading states. Expanded sidebar carries navigation and account/sync status. Reader controls retain tooltips and platform shortcuts; selected drawing tools use primary-container. Touch with the hand tool toggles reader chrome; desktop chrome stays visible.

### Annotation browser and reader status

Annotation search matches text or page, with All/Highlights/Notes/Ink filters. Items navigate to their real page and offer appropriate edit/delete actions; ink uses a drawn preview. Copy as Markdown copies annotation descriptions to the clipboard; it does not export an annotated PDF. The square page/zoom status control opens page navigation and zoom presets.

## Do's and Don'ts

### Do:

- Do use the shared AppTheme semantic color roles in both appearances.
- Do keep Material semantics, tooltips, keyboard shortcuts and input policy.
- Do preserve real PDF rendering and local-first synchronization behavior.
- Do use bundled JetBrains Mono for UI and keep document typography intact.

### Don't:

- Don't use ui-showcase.html as a design reference.
- Don't add rounded cards, gradients or decorative shadows to the approved square workspace.
- Don't describe Flutter web captures as native device evidence.
- Don't ship generated raster decoration or imply PDF-file annotation export from Markdown copying.

The system is documented from Flutter source and browser review. Native tablet library portrait/landscape smoke checks and phone/tablet launcher icon/name checks subsequently passed after build 11 was installed on both devices. Native reader, gestures, font scaling, stylus and performance coverage remain incomplete; browser captures do not certify those behaviors. Launcher PNGs are rasterized from the PDF mark vector/font outlines by scripts/generate-android-icon.py; bundled fonts carry OFL.txt. The approved implementation contract records the current scope.
