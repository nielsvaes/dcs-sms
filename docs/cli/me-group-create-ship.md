# `dcs-sms me group create-ship`

[← CLI reference index](README.md)

spawn a new ship group at the given coordinates

## Usage

```
dcs-sms me group create-ship [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--country` | string | `""` | country in current mission |
| `--east` | float | `0` | meters east of theatre origin |
| `--force` | bool | `false` | skip the water-surface check |
| `--heading` | float | `0` | heading in degrees (0 = north, CW positive) |
| `--name` | string | `""` | group name (auto-allocated if empty) |
| `--north` | float | `0` | meters north of theatre origin |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--skill` | string | `Average` | AI skill |
| `--task` | string | `""` | group task; default "CAP" |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | ship id (e.g. CVN_71_THEODORE_ROOSEVELT, FFG_7CL_OliverHazardPerry) |

---

[← CLI reference index](README.md)
