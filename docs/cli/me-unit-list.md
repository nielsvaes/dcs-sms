# `dcs-sms me unit list`

[← CLI reference index](README.md)

list all units in the open mission

## Usage

```
dcs-sms me unit list [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--category` | string | `""` | filter by category: plane \| helicopter \| vehicle \| ship \| static |
| `--country` | string | `""` | filter by country (case-insensitive exact match) |
| `--group` | string | `""` | filter by group name (exact match) |
| `--name` | string | `""` | filter by unit-name substring (case-insensitive) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--side` | string | `""` | filter by side: red \| blue \| neutrals |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--type` | string | `""` | filter by airframe / unit type (exact match; comma-separate for any-of, e.g. flak18,flak36,bofors40) |

---

[← CLI reference index](README.md)
