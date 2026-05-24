# `dcs-sms me coords to-geo`

[← CLI reference index](README.md)

convert DCS local meters (north/east) to geographic lat/lon for the current theatre

## Usage

```
dcs-sms me coords to-geo [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--alt` | float | `0` | altitude in meters (optional; echoed back unchanged) |
| `--east` | float | `0` | meters east of theatre origin (east positive) |
| `--north` | float | `0` | meters north of theatre origin (north positive) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
