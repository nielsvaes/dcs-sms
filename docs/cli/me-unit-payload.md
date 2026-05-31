# `dcs-sms me unit payload`

[← CLI reference index](README.md)

manage a unit's per-pylon weapon payload (sub-verbs: set, clear, set-fuze, list-settings)

## Usage

```
dcs-sms me unit payload <set|clear|set-fuze|list-settings> [flags]
```

## `set`

set a single pylon's weapon (--weapon accepts a CLSID or display name)

| Name | Type | Default | Description |
|---|---|---|---|
| `--id` | int | `0` | unit id (mutually exclusive with --name) |
| `--name` | string | `""` | unit name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--pylon` | int | `0` | pylon number (per-airframe, see DB.unit_by_type[type].Pylons) |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--weapon` | string | `""` | weapon CLSID (e.g. "{GUID}") or display name |

## `clear`

remove a single pylon's weapon entry

| Name | Type | Default | Description |
|---|---|---|---|
| `--id` | int | `0` | unit id (mutually exclusive with --name) |
| `--name` | string | `""` | unit name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--pylon` | int | `0` | pylon number |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

## `set-fuze`

set per-pylon weapon settings (fuzes, function delays, presets) via repeatable --set, validated against the weapon's descriptor

| Name | Type | Default | Description |
|---|---|---|---|
| `--id` | int | `0` | unit id (mutually exclusive with --name) |
| `--name` | string | `""` | unit name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--pylon` | int | `0` | pylon number (per-airframe) |
| `--saved-games` | string | `""` | override Saved Games path |
| `--set` | string (repeatable) | `""` | setting as "<id-or-label>=<value>" (repeatable). Key matches a descriptor id or label; value matches a combo id/name or numeric value. Discover legal keys with `me unit payload list-settings`. |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--weapon` | string | `""` | optional weapon CLSID or display name to set on the pylon first |

## `list-settings`

dump a weapon's configurable-settings descriptor (ids, labels, combo values, defaults)

| Name | Type | Default | Description |
|---|---|---|---|
| `--id` | int | `0` | unit id (mutually exclusive with --name) |
| `--name` | string | `""` | unit name (mutually exclusive with --id) |
| `--pretty` | bool | `false` | indent JSON output |
| `--pylon` | int | `0` | pylon number (resolves the weapon from the current loadout) |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--weapon` | string | `""` | weapon CLSID or display name (overrides --pylon's weapon) |

---

[← CLI reference index](README.md)
