# `dcs-sms me group set-uncontrollable`

[← CLI reference index](README.md)

toggle a group's GAME MASTER ONLY (g.uncontrollable) flag

## Usage

```
dcs-sms me group set-uncontrollable [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--enabled` | bool | `false` | set GAME MASTER ONLY (true) or clear it (false); pass explicitly |
| `--id` | int | `0` | group id (mutually exclusive with --name) |
| `--name` | string | `""` | group name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
