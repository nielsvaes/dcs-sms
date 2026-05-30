# `dcs-sms me group focus`

[← CLI reference index](README.md)

raise the AIRPLANE/HELICOPTER GROUP and route panels for a group (same UI state as a map click)

## Usage

```
dcs-sms me group focus [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--id` | int | `0` | group id (mutually exclusive with --name) |
| `--name` | string | `""` | group name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
