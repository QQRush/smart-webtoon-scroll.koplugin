# Smart Webtoon Scroll for KOReader

<p align="center">
  <img src="Immagine%20ChatGPT%2030%20set%202026,%2010_43_24.png" alt="Smart Webtoon Scroll v0.2.7.24 overview" width="100%">
</p>

A lightweight KOReader plugin designed for **vertical webtoons stored as CBZ/CBR files**.

Smart Webtoon Scroll turns the images inside a comic archive into a **continuous vertical strip** and makes page turns behave more naturally: fewer cut panels, less empty space, smoother chapter transitions, and adaptive rendering for different screen shapes.

## 🎬 See it in action

▶️ **[Watch Smart Webtoon Scroll in action on YouTube Shorts](https://www.youtube.com/shorts/S9LCgv_EFD0)**

See how Smart Webtoon Scroll keeps panels and dialogue together while navigating a vertical webtoon in KOReader.

## Current version

**0.2.7.24 — Adaptive Full-Screen Background**

This is the current recommended stable build.

## Highlights

- **Continuous vertical strip** — consecutive CBZ/CBR images behave like one long webtoon.
- **Smart separator snapping** — detects white and black horizontal separator bands and tries to place screen boundaries at cleaner visual positions.
- **Fit-to-Height** — slightly oversized content can be reduced just enough to remain together on one screen.
- **Full-screen adaptive background** — the visible content is sampled and the entire viewport is filled with a matching black or white background before the webtoon is rendered. This keeps Fit-to-Height and margins visually seamless.
- **Symmetric Sidebar** — optional 1–20% side space for wider displays such as 3:2 screens. The space is divided equally between left and right so the webtoon stays centered.
- **Configurable Render Preload** — choose how many upcoming pages are prepared in advance for smoother navigation.
- **Cross-file continuity** — artwork can continue naturally across physical images inside the archive.
- **Seamless chapter navigation** — moving forward from the last Smart Screen opens the next chapter; moving backward from the first Smart Screen opens the previous chapter.
- **Previous chapter → last Smart Screen** — when going back a chapter, the plugin positions you at that chapter's final Smart Screen instead of starting from the top.
- **Compact, scrollable settings** — shorter labels and a vertically scrollable settings window work better on small screens.
- **Lightweight analysis** — separator detection uses cached low-resolution analysis instead of expensive panel recognition.

## Before → After

Without the plugin, a normal page boundary may cut through artwork or dialogue and leave large blank areas. Smart Webtoon Scroll searches around the natural page boundary for a cleaner separator and keeps the reading flow visually continuous whenever possible.

The plugin intentionally **does not perform complex panel detection**. Its goal is to remain lightweight while making ordinary page-turn reading feel much better for vertical webtoons.

## How it works

Each physical image is fitted into a virtual vertical strip. When you move forward or backward, Smart Webtoon Scroll calculates the next viewport and looks nearby for a suitable white or black separator.

If content is only slightly taller than the display, **Fit-to-Height** can shrink that section within the configured limit. When margins are exposed, the **adaptive full-screen background** fills the whole viewport with black or white according to the visible artwork.

On wider screens, **Symmetric Sidebar** can intentionally reduce the reading width while keeping the content centered.

## Installation

1. Download the latest release.
2. Extract/copy `smartwebtoonscroll.koplugin` into KOReader's `plugins` directory.
3. Restart KOReader.
4. Open a CBZ/CBR and enable **Smart Webtoon Scroll** from the KOReader menu.

```text
koreader/
└── plugins/
    └── smartwebtoonscroll.koplugin/
        ├── _meta.lua
        └── main.lua
```

## Main controls

- Enable continuous strip
- Fit slightly oversized content to height
- Sidebar ON/OFF
- Next Smart Screen
- Previous Smart Screen
- Scroll settings
- Reset at current CBZ image

## Settings

The compact settings window includes controls for:

| Setting | Purpose |
| --- | --- |
| Search range (%) | How far around the normal boundary the plugin searches for a separator |
| Panel overlap (%) | Overlap retained when long content must be split |
| Min separator (px) | Minimum size of a detected separator band |
| White threshold | Sensitivity for white separator detection |
| Max Fit reduction (%) | Maximum reduction allowed by Fit-to-Height |
| Preload pages | Number of upcoming pages prepared in advance |
| Sidebar width (%) | Total symmetric side space, adjustable from 1–20% |

## What's new in v0.2.7.24

- Full-viewport adaptive black/white background.
- Symmetric configurable Sidebar for wider displays.
- Configurable render preload.
- Improved next/previous chapter navigation.
- Returning to a previous chapter now opens its last Smart Screen.
- Compact and scrollable settings interface.
- Cleaner handling of chapter boundaries while keeping normal scrolling lightweight.

## Notes

Smart Webtoon Scroll is primarily intended for **fixed-layout vertical webtoons in CBZ/CBR archives**. Different webtoons use different image sizes, separator styles and artwork backgrounds, so some titles may benefit from small adjustments to the separator, overlap or Fit settings.

## Credits

Smart Webtoon Scroll grew from experiments with continuous webtoon reading in KOReader and incorporates integration/rendering ideas inspired by **Webtoon Helper 2.2.4**.

## Status

`0.2.7.24` is the current recommended stable build.