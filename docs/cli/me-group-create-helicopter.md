# `dcs-sms me group create-helicopter`

[← CLI reference index](README.md)

spawn a new helicopter group at the given coordinates

## Usage

```
dcs-sms me group create-helicopter [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--alt` | float | `1000` | altitude in meters above sea level |
| `--alt-type` | string | `BARO` | altitude reference: BARO or RADIO |
| `--country` | string | `""` | country in current mission (e.g. USA, Russia) |
| `--east` | float | `0` | meters east of theatre origin |
| `--frequency` | float | `127.5` | radio frequency MHz |
| `--heading` | float | `0` | heading in degrees (0 = north, CW positive) |
| `--livery` | string | `""` | livery id |
| `--name` | string | `""` | group name (auto-allocated if empty) |
| `--north` | float | `0` | meters north of theatre origin |
| `--onboard-num` | string | `010` | onboard number |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--skill` | string | `Average` | AI skill |
| `--speed` | float | `50` | speed in m/s |
| `--task` | string | `""` | group task (e.g. "CAS", "Transport"); default "Transport" |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | airframe id (e.g. UH-60L, Mi-8MT) |

---

[← CLI reference index](README.md)
