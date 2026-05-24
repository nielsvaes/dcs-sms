# `dcs-sms me drawing list`

[← CLI reference index](README.md)

list all drawings in the open mission

## Usage

```
dcs-sms me drawing list [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--layer` | string | `""` | Red \| Blue \| Neutral \| Common \| Author |
| `--mode` | string | `""` | circle \| oval \| rect \| free \| arrow \| segments \| segment |
| `--name` | string | `""` | name substring (case-insensitive) |
| `--name-prefix` | string | `""` | anchored name prefix (case-insensitive); combines with --name if both given |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | Line \| Polygon \| TextBox \| Icon |

---

[← CLI reference index](README.md)
