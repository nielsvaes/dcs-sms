# `dcs-sms me waypoint list-tasks`

[← CLI reference index](README.md)

list legal task ids from ED's me_action_db, optionally filtered by group and/or --kind

## Usage

```
dcs-sms me waypoint list-tasks [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--group-id` | int | `0` | filter to tasks legal for this group's main task (mutually exclusive with --group-name) |
| `--group-name` | string | `""` | filter to tasks legal for this group's main task (mutually exclusive with --group-id; omit both to list all) |
| `--kind` | string | `""` | optional filter: 'waypoint' or 'enroute' (omit for both) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
