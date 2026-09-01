# Omarchy Night Light

Night Light is an Omarchy bar widget that smoothly warms the display from calculated sunset to sunrise. Solar times are calculated locally: after a location has been selected, the daily schedule continues to work offline.

It uses the session's existing `hyprsunset` when possible and coexists with Omarchy's first-party Night Light service. It does not disable that service, kill a shared daemon, or change Omarchy Weather.

## Install

> Omarchy plugins run unsandboxed as your user. Review the repository and install only from a URL you trust.

Install and enable the plugin from this machine’s canonical Git checkout:

```sh
omarchy plugin add file:///home/jgordijn/Work/omarchy-night-light --enable
```

This produces a Git-managed installation that `omarchy plugin update` can update. On another machine, clone or publish this repository first, then pass that trusted Git URL.

Omarchy validates and clones the plugin to:

```text
~/.config/omarchy/plugins/jgordijn.night-light
```

The widget is added to the right side of the bar. Installation runs no install hook, uses no `sudo`, installs no system package, performs no location lookup, and makes no change to systemd or the first-party `omarchy.nightlight` service.

To review a checkout before enabling it, omit `--enable`, inspect the files, then run:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/jgordijn.night-light
omarchy plugin enable jgordijn.night-light
```

## First use and location

Open the **Night Light** bar item. The schedule needs latitude and longitude, but not a sunrise/sunset service.

Location options are:

- **Use Weather location** — reuses valid coordinates already selected in Omarchy Weather. This is read-only and causes no Night Light network request.
- **Manual location** — enter strict decimal coordinates, such as `52.27115, 5.13729`, for completely offline setup; or search for a locality using Open-Meteo while the editor is open.
- **Automatic (approximate)** — only after an explicit confirmation, contacts wttr.in. The provider sees the public IP and returns an approximate city. Review the result before accepting it.

A fresh install automatically adopts valid Omarchy Weather coordinates when available. Missing or malformed Weather data never falls back to IP location. Once coordinates are saved, schedule calculation is local and remains available offline.

On first open, Night Light may also offer to hide the stock `NightLight` shortcut. This is optional: choose **Keep both** to make no change, or **Hide stock shortcut** to remove only that indicator from the bar. The first-party Night Light service remains enabled either way.

## Use

The panel shows the current phase, actual display state, next solar transition, location source, warmth, and transition duration.

### Pointer controls

- **Left click:** open or close the panel.
- **Right click:** switch immediately between manual warmth and daylight.
- **Middle click:** resume the automatic solar schedule.

A manual choice is held until the next sunset or sunrise. Changes made through Omarchy's stock shortcut, `omarchy toggle nightlight`, a native `hyprsunset` profile, or direct `hyprctl` are adopted as manual overrides instead of being fought by the plugin. Select **Resume automatic** to return immediately to the calculated target.

### Settings

- **Automatic:** pause or resume scheduled changes.
- **Warmth:** night temperature from 1000 K to 6500 K; default 4000 K. The panel changes it in 250 K steps.
- **Transition:** instant or a gradual sunset/dawn transition; default 45 minutes.
- **Location:** switch source, search, enter coordinates, or forget the saved Night Light location.

### Keyboard controls

With the panel open:

- `Up`/`Down` or `k`/`j`: move between controls.
- `Left`/`Right`: change the focused value.
- `Enter` or `Space`: activate the focused control.
- `n`: use warmth/daylight now.
- `a`: resume automatic mode.
- `l`: open the location editor.
- `Tab`/`Shift+Tab`: move to adjacent visible bar panels; inside an editor, move between editor controls.
- `Escape`: cancel the editor or close the panel.

### Diagnostics and control

The service exposes direct-target IPC without including coordinates in status output. The read-only status call is:

```sh
omarchy-shell jgordijn.night-light status
```

It reports plugin and display state without changing either or making a network request. The remaining calls can change the display setting:

```sh
omarchy-shell jgordijn.night-light refresh
omarchy-shell jgordijn.night-light warm
omarchy-shell jgordijn.night-light daylight
omarchy-shell jgordijn.night-light resume
```

`refresh` recalculates the schedule, reconciles the current scheduled target, and probes the display backend; it does not request a location from the network. `warm` and `daylight` create a manual override, while `resume` immediately returns to the calculated target.

## Privacy

Night Light does not use GeoClue, GPS, Wi-Fi identifiers, SSIDs/BSSIDs, or a sunrise/sunset web API. It does not save an IP address, provider response history, manual search text, or raw provider responses.

### Network access

| Action | Network behavior |
| --- | --- |
| Reuse Omarchy Weather coordinates | No Night Light request |
| Enter direct coordinates | No request |
| Calculate solar times or run the schedule | No request |
| Search for a locality | HTTPS to `geocoding-api.open-meteo.com`, only after the Manual Location editor is opened and text is entered |
| Choose Automatic (approximate) | HTTPS to `wttr.in`, only after explicit consent; the provider sees the public IP |

Only the accepted locality and coordinates are cached, not an IP address or a history of results. An accepted approximate location remains usable offline. Automatic results are always labeled **Approximate**, and possible VPN or proxy inaccuracy is shown before use.

### Local data

Night Light reads Omarchy Weather's state when Weather mode is selected, but never writes or deletes it.

It stores:

- Schedule preferences and optional stock-indicator restoration metadata in `~/.config/omarchy/shell.json`.
- The selected location, source, consent version, and accepted location cache in `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/settings/jgordijn.night-light.json`.
- Session-only controller coordination under `$XDG_RUNTIME_DIR/jgordijn-night-light/$HYPRLAND_INSTANCE_SIGNATURE/`.

The private location file and runtime files are user-only (`0600`) in user-only directories (`0700`). Location updates are atomic. Diagnostics omit coordinates, search queries, provider bodies, public IPs, and route details. The status command does include the human-readable accepted location label and source.

Choose **Forget location** in the panel to delete Night Light's private location state and consent. This stops scheduled display writes and leaves the current display setting unchanged. Omarchy Weather remains untouched.

## Disable, update, and uninstall

Temporarily disable the plugin without deleting its saved location:

```sh
omarchy plugin disable jgordijn.night-light
```

After an eight-second reload grace period, the controller restores the display state it found at startup only if no other program changed that state in the meantime. It never stops an unowned `hyprsunset` process.

Update from the installed Git checkout with:

```sh
omarchy plugin update jgordijn.night-light
```

Before removal:

1. If the plugin hid Omarchy's stock shortcut, open Night Light settings and choose **Restore stock shortcut**. Restoration is compare-and-swap safe; if Bar settings changed since setup, restore `NightLight` manually in Omarchy Bar settings instead.
2. For a zero-location-data uninstall, choose **Forget location** and confirm.
3. Remove the plugin:

```sh
omarchy plugin remove jgordijn.night-light
```

Omarchy has no plugin-specific post-remove hook, so ordinary removal deliberately retains the private location file. If the plugin has already been removed, delete only its state file manually:

```sh
state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}
rm -f -- "$state_root/omarchy/settings/jgordijn.night-light.json"
```

Do not delete `weather.json`; it belongs to Omarchy Weather.

## License

[MIT](LICENSE) © 2026 Jeroen Gordijn
