# Countdown

Countdowns for the [Omarchy](https://omarchy.org) bar. The widget shows the
time remaining until a deadline, can draw progress below the label, and opens
a panel for managing multiple countdowns.

<p align="center">
  <img src="preview.png" alt="Countdown bar widget and management panel" width="430">
</p>

## Screenshots

### Bar widget

<p align="center">
  <img src="screenshots/bar.png" alt="Countdown in the Omarchy bar" width="200">
</p>

### Management panel

<p align="center">
  <img src="screenshots/configuration.png" alt="Countdown management panel with example entries" width="399">
</p>

The screenshots use fictional example deadlines. No personal countdown data is
included in this repository.

## Installation

```bash
omarchy plugin add https://github.com/CristianoCorsi/omarchy-countdown.git --enable
```

The public plugin ID is `cristianocorsi.countdown`.

## Usage

| Gesture | Effect |
| --- | --- |
| Click | Open the management panel |
| Right click | Select the next countdown |
| Scroll | Cycle through countdowns |

From the panel you can add, edit, reorder, and delete entries. Clicking an
entry selects the countdown shown in the bar.

### IPC

```bash
omarchy-shell cristianocorsi.countdown toggle
omarchy-shell cristianocorsi.countdown next
omarchy-shell cristianocorsi.countdown previous
```

## Settings

Configure these values from Omarchy's bar settings or directly on the widget
entry in `~/.config/omarchy/shell.json`.

| Key | Default | Description |
| --- | --- | --- |
| `format` | `days` | `days`, `percentage`, or `auto` |
| `maxLabel` | `16` | Maximum label length before truncation |
| `showProgress` | `true` | Draw progress below the label |
| `alertDays` | `3` | Highlight the widget below this number of days |

The `auto` format shows days while more than one day remains, then switches to
hours and finally minutes.

## State

Countdown data is stored locally in
`~/.local/state/omarchy/countdown.json`:

```json
{
  "state": { "current_index": 0 },
  "countdowns": [
    {
      "label": "Release 1.0",
      "start": "2030-01-01",
      "end": "2030-03-31",
      "format": "days"
    }
  ]
}
```

`start` is used to calculate progress. The plugin accepts non-zero-padded dates
for compatibility, but writes dates back in canonical `YYYY-MM-DD` form. The
file is watched for changes so multiple monitors stay in sync.

## Update and removal

```bash
omarchy plugin update cristianocorsi.countdown --yes
omarchy plugin remove cristianocorsi.countdown
```

## Development

Validate the plugin before publishing:

```bash
omarchy plugin validate .
```

## License

MIT — see [LICENSE](LICENSE).
