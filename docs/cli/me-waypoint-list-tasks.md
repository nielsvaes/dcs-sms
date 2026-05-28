# `dcs-sms me waypoint list-tasks`

[← CLI reference index](README.md)

list legal task ids from ED's me_action_db, optionally filtered by --kind

## Usage

```
dcs-sms me waypoint list-tasks [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--kind` | string | `""` | optional filter: 'waypoint' or 'enroute' (omit for both) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
