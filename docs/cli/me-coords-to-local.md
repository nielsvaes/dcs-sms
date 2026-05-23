# `dcs-sms me coords to-local`

[← CLI reference index](README.md)

convert geographic lat/lon to DCS local meters (north/east) for the current theatre

## Usage

```
dcs-sms me coords to-local [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--alt` | float | `0` | altitude in meters (optional; echoed back unchanged) |
| `--lat` | float | `0` | latitude in degrees (north positive) |
| `--lon` | float | `0` | longitude in degrees (east positive) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
