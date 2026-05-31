# `dcs-sms me trigger create`

[← CLI reference index](README.md)

create a new trigger (start / once / continuous / front)

## Usage

```
dcs-sms me trigger create [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--action` | string (repeatable) | `""` | bundled action (repeatable): "<predicate> k=v..." |
| `--condition` | string (repeatable) | `""` | bundled condition (repeatable): "<predicate> k=v..." |
| `--name` | string | `""` | trigger name (defaults to "Trigger <epoch>") |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | trigger type: once\|continuous\|start\|front |

---

[← CLI reference index](README.md)
