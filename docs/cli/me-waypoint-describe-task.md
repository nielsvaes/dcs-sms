# `dcs-sms me waypoint describe-task`

[← CLI reference index](README.md)

print the parameter schema (fields, defaults, allowed values) of one task id

## Usage

```
dcs-sms me waypoint describe-task [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--kind` | string | `""` | optional filter: 'waypoint' or 'enroute' |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--task` | string | `""` | task id (e.g. Bombing, EngageTargets) |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
