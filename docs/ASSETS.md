# Bundled brand assets

| Asset | Source | Notes |
| --- | --- | --- |
| `HCGSentinel/Resources/Assets.xcassets/HCGMark.imageset/hcg-mark@1x.png`, `hcg-mark@2x.png` | HCG Store (`F1r3srp3nt/store`, commit `835ac1a`): `web-hcg-store/public/brand/hcg-mark-240.webp` (SHA-256 `aeacc502…d5c87ab`) and `hcg-mark-480.webp` (SHA-256 `c56b4893…fa98dc7`) — the mark in Store's navigation header | The chrome and cyan HCG mark (Store's `docs/ASSETS.md`: the temporary official HCG logo provided by the founder). Decoded to PNG without loss: every pixel, alpha included, equals Store's file; 240 × 109 and 480 × 218, aspect ratio unchanged. Bundled in the app, so it needs no network. Used by `BrandLockup` on the dashboard. |
| `HCGSentinel/Resources/Assets.xcassets/SentinelHeader.imageset` | Earlier Sentinel banner | Still used in the iPad sidebar. |
