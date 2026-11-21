# iPhone beta checklist

A short manual pass for a development build on your own iPhone. Distribution stays manual: nothing here uploads to
TestFlight or the App Store. Write each result (pass, fail, or not tried) in `docs/VALIDATION.md` under "Record your
own results here", with the phone model, its iOS version and the commit.

## 0. Build and install

| Phone | Scheme |
| --- | --- |
| iOS 15.0 or later (for example an iPhone 13 Pro Max on 17.4) | `HCGSentinelModern` |
| iOS 14.7 (the iPhone X) | `HCGSentinel`, only with an Xcode that still accepts 14.7 (16.4 or 26.x) |

In Maker: Mobile Build Studio › check that **Imported copy** matches this revision (hashes in
[MAKER.md](MAKER.md#is-maker-building-this-revision), or press **Refresh source**) › scheme › signing **Automatic**
with your Team ID › output **IPA**, export method **development**.

Without Maker, on the Mac:

```bash
DEVELOPMENT_TEAM=YOURTEAMID FLAVOR=modern Tools/build.sh archive
```

```bash
DEVELOPMENT_TEAM=YOURTEAMID FLAVOR=modern Tools/build.sh export
```

The IPA is in `build/ipa/`. Install it with Xcode › Window › Devices and Simulators › your iPhone › **+**, or press
Run in Xcode with the phone selected. On first launch iOS may ask you to trust the developer: Settings › General ›
VPN & Device Management.

- [ ] The app installs, and the home screen shows **Sentinel** with its icon.

## 1. Launch

- [ ] It opens to the dashboard with no sign-in and no account prompt.
- [ ] The header shows the metallic HCG mark, a divider and **SENTINEL**, with the status badge beside or below it.
      Nothing is clipped or overlaps.
- [ ] A soft blue light moves slowly along the line under the header. With Settings › Accessibility › Motion ›
      **Reduce Motion** on, the line is static. Sentinel's own Settings › Animations switch does the same.
- [ ] With Settings › Accessibility › Display & Text Size › **Larger Text** at the largest standard size, the header
      and dashboard cards still read fully (the header scales down to fit; text wraps rather than truncating).
- [ ] Force-quit and relaunch: it opens again and keeps your settings.

## 2. Permission handling

Bluetooth (the first scan triggers the prompt):

- [ ] Bluetooth Explorer opens without asking for anything. With Sentinel's Scanning switch off, the card reads
      **Scanning is off** and offers to turn scanning on and start.
- [ ] Starting a scan shows the iOS prompt with Sentinel's reason ("…only when you start a scan in Bluetooth
      Explorer…"). The card reads **Starting…** while the prompt is up.
- [ ] Choose **Don't Allow**: the card turns to **Bluetooth permission denied** with a button to open iOS Settings,
      and no devices are listed. Allow it in iOS Settings › Sentinel › Bluetooth, return, start again: it scans.
- [ ] Turn Bluetooth off in Control Centre while on the screen: the card reads **Bluetooth is off**; nothing is
      listed as new. Turn it back on and start again.

Local network (only when you use it):

- [ ] Check My Network and the dashboard do not ask for local-network access on launch.
- [ ] The first request to a local address (Request Composer, or your own radio node) shows the local-network
      prompt. If you refuse it, the request fails with the error iOS reports, shown in the app; no crash, no empty
      screen. (Sentinel does not yet say in its own words that local-network access is off.)

## 3. Bluetooth discovery

Do this somewhere with a few Bluetooth LE devices nearby (headphones, a watch, a fitness tracker, another phone).

- [ ] The scan controls and the first results are visible at the top of Bluetooth Explorer without scrolling.
- [ ] The card reads **Scanning · N devices heard**, and devices appear within a few seconds.
- [ ] Devices without a broadcast name are listed as **Unknown device**, not guessed.
- [ ] Each row shows **Signal −NN dBm**; closer devices have a less negative number.
- [ ] Open a result. It shows where the name came from (broadcast name, your label, or unknown), the advertised
      services, **Latest signal strength (RSSI)** with a small history chart and the last timestamped readings, and
      when it was last seen.
- [ ] Give a device a label, go back: the label shows in the list and in the "Labelled only" filter. It is still
      there after relaunching the app.
- [ ] Search, the sort order and each filter (named, labelled, current scan, connectable, advertising services,
      signal strength) change the list as their names say; **Reset filters** brings everything back.
- [ ] **Stop**: the card reads **Stopped · N devices listed** and the results stay. Start again: the scan number
      increases. The scan also stops by itself at the time limit shown on the card.
- [ ] Somewhere with nothing advertising (or with every device switched off), after about 15 s the card reads
      **Scanning · nothing heard yet** and explains why.

## What this checklist does not cover

Sign-in with an HCG account does not exist yet (see [HCG_CONNECT.md](HCG_CONNECT.md)). Security Lab against an HCG
Server, the helper link and the radio node each have their own pages in [TESTING.md](TESTING.md).
