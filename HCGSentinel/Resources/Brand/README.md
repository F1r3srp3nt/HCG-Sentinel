# Brand resources

Bundled with the app so the dashboard header works offline.

| File | Source | Notes |
| --- | --- | --- |
| `hcg-mark-240.webp`, `hcg-mark-480.webp` | HCG Store, `web-hcg-store/public/brand/` (F1r3srp3nt/store, commit 835ac1a) | Byte-for-byte copies of the chrome HCG mark used in Store's navigation header. 240×109 and 480×218, with alpha. Not re-encoded. |
| `SpaceGrotesk-SemiBold.ttf` | Space Grotesk 2.0 variable font (github.com/floriankarsten/space-grotesk, commit 03507d0), instanced at weight 600 with fontTools | The display font Store uses for its "STORE" word (weight 600). Licensed under the SIL Open Font License 1.1, see `SpaceGrotesk-OFL.txt`; no Reserved Font Name is declared. |

The lockup metrics in `HCGLockup` (Theme.swift) are Store's `.brand` CSS: mark 88 px wide, 10 px gap, 1 px divider
`rgba(206, 220, 236, 0.15)` as tall as one 15 px line at line-height 1.6 (24 px), 12 px padding, word in Space
Grotesk 600 at 15 px with 0.32 em letter spacing, colour `#f4f6f9`. Sentinel scales all of them by one factor.
