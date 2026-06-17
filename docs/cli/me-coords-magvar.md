# `dcs-sms me coords magvar`

[← CLI reference index](README.md)

magnetic declination (degrees, East +) at a point for the open mission's date

## Usage

```
dcs-sms me coords magvar [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--east` | float | `0` | meters east of theatre origin (pair with --north) |
| `--lat` | float | `0` | latitude in degrees (pair with --lon) |
| `--lon` | float | `0` | longitude in degrees (pair with --lat) |
| `--north` | float | `0` | meters north of theatre origin (pair with --east) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
