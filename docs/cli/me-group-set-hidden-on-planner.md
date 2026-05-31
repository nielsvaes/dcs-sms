# `dcs-sms me group set-hidden-on-planner`

[← CLI reference index](README.md)

toggle a group's HIDDEN ON PLANNER flag

## Usage

```
dcs-sms me group set-hidden-on-planner [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--hidden` | bool | `false` | hide on planner (true) or show (false); pass explicitly |
| `--id` | int | `0` | group id (mutually exclusive with --name) |
| `--name` | string | `""` | group name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
