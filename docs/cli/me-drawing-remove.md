# `dcs-sms me drawing remove`

[← CLI reference index](README.md)

delete one or many drawings from the open mission

## Usage

```
dcs-sms me drawing remove [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--all` | bool | `false` | required when deleting by --layer alone (no --name or --name-prefix); deletes every drawing on that layer |
| `--layer` | string | `""` | scope to layer: Red \| Blue \| Neutral \| Common \| Author |
| `--name` | string | `""` | drawing name (exact, single delete) |
| `--name-prefix` | string | `""` | batch delete: name prefix (case-insensitive); combines with --layer |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
