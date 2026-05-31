# `dcs-sms me group create-plane`

[← CLI reference index](README.md)

spawn a new plane group at the given coordinates

## Usage

```
dcs-sms me group create-plane [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--alt` | float | `8000` | altitude in meters above sea level |
| `--alt-type` | string | `BARO` | altitude reference: BARO or RADIO |
| `--country` | string | `""` | country name in current mission (e.g. USA, Russia) |
| `--east` | float | `0` | meters east of theatre origin (east positive) |
| `--frequency` | float | `251` | radio frequency MHz |
| `--heading` | float | `0` | heading in degrees (0 = north, CW positive) |
| `--livery` | string | `""` | livery id ('' = default) |
| `--name` | string | `""` | group name (auto-allocated if empty) |
| `--north` | float | `0` | meters north of theatre origin (north positive) |
| `--onboard-num` | string | `010` | onboard number (display only) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--skill` | string | `Average` | AI skill: Average, Good, High, Excellent, Random, Player |
| `--speed` | float | `220` | speed in m/s |
| `--task` | string | `""` | group task (e.g. "CAP", "CAS", "Ground Attack"); default "Nothing" |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | airframe id (e.g. F-16C_50, Su-27) |

---

[← CLI reference index](README.md)
