# `dcs-sms me unit get`

[← CLI reference index](README.md)

return full data for a unit (by --name/--id, or first unit of a group via --group-name/--group-id)

## Usage

```
dcs-sms me unit get [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--group-id` | int | `0` | parent groupId (returns the first unit of that group) |
| `--group-name` | string | `""` | parent group name (returns the first unit of that group) |
| `--id` | int | `0` | unitId (numeric) |
| `--name` | string | `""` | unit name (exact match) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
