# `dcs-sms me waypoint remove-task`

[← CLI reference index](README.md)

remove a waypoint-kind task by 1-based slot

## Usage

```
dcs-sms me waypoint remove-task [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--group-id` | int | `0` | group id (mutually exclusive with --group-name) |
| `--group-name` | string | `""` | group name (mutually exclusive with --group-id) |
| `--index` | int | `-1` | waypoint index (0-based; required) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--slot` | int | `0` | 1-based slot in wp.task.params.tasks (required) |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
