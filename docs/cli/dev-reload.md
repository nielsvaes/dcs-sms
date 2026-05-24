# `dcs-sms dev-reload`

[← CLI reference index](README.md)

build the .exe, reinstall the ME mod, and hot-reload it in one shot (contributor workflow)

## Usage

```
dcs-sms dev-reload [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--dcs-path` | string | `""` | override DCS install path (forwarded to install-me-mod) |
| `--saved-games` | string | `""` | override Saved Games path (forwarded to reload-me-mod) |
| `--timeout` | duration | `10s` | reload timeout (forwarded to reload-me-mod) |
| `--wait` | bool | `false` | if bridge isn't ready, poll until it is (forwarded to reload-me-mod) |

---

[← CLI reference index](README.md)
