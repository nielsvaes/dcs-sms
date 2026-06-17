# `dcs-sms me waypoint get`

[← CLI reference index](README.md)

get a single waypoint's full field set. A WP's speed/ETA is the value on arrival at that WP (the inbound leg), not the departure leg; WP0 (takeoff) and the final (landing) WP carry a DCS placeholder speed, not a cruise speed.

## Usage

```
dcs-sms me waypoint get [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--group-id` | int | `0` | group id (mutually exclusive with --group-name) |
| `--group-name` | string | `""` | group name (mutually exclusive with --group-id) |
| `--index` | int | `-1` | waypoint index (0-based; required) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
