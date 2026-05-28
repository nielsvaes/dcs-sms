# `dcs-sms me waypoint add-enroute-task`

[← CLI reference index](README.md)

append an enroute-kind task to a waypoint's ComboTask

## Usage

```
dcs-sms me waypoint add-enroute-task [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--group-id` | int | `0` | group id (mutually exclusive with --group-name) |
| `--group-name` | string | `""` | group name (mutually exclusive with --group-id) |
| `--index` | int | `-1` | waypoint index (0-based; required) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--task` | string | `""` | task id from me_action_db (e.g. EngageTargets, CAP, EngageGroup). Run `me waypoint list-tasks --kind enroute` to see legal ids. |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
