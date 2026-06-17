# `dcs-sms me route list`

[← CLI reference index](README.md)

list waypoints on a group's route (compact summary per WP). A WP's speed/ETA is the value on arrival at that WP (the inbound leg), not the departure leg; WP0 (takeoff) and the final (landing) WP carry a DCS placeholder speed, not a cruise speed.

## Usage

```
dcs-sms me route list [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--group-id` | int | `0` | group id (mutually exclusive with --group-name) |
| `--group-name` | string | `""` | group name (mutually exclusive with --group-id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
