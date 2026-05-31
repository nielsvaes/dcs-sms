# `dcs-sms me group create-vehicle`

[← CLI reference index](README.md)

spawn a new ground vehicle group at the given coordinates

## Usage

```
dcs-sms me group create-vehicle [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--country` | string | `""` | country in current mission |
| `--east` | float | `0` | meters east of theatre origin |
| `--heading` | float | `0` | heading in degrees (0 = north, CW positive) |
| `--name` | string | `""` | group name (auto-allocated if empty) |
| `--north` | float | `0` | meters north of theatre origin |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--skill` | string | `Average` | AI skill |
| `--task` | string | `""` | group task; default "Ground Nothing" |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | vehicle id (e.g. M-1 Abrams, T-72B) |

---

[← CLI reference index](README.md)
