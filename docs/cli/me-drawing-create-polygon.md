# `dcs-sms me drawing create-polygon`

[← CLI reference index](README.md)

draw a free-mode polygon on the F10 map

## Usage

```
dcs-sms me drawing create-polygon [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--color` | string | `""` | outline color (default red, opaque) |
| `--fill-color` | string | `""` | fill color (default red, half alpha) |
| `--hidden-on-planner` | bool | `false` | hide on mission planner |
| `--layer` | string | `""` | Red\|Blue\|Neutral\|Common\|Author (default Common) |
| `--name` | string | `""` | drawing name (auto-allocated if empty) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--style` | string | `""` | line style (default solid) |
| `--thickness` | float | `0` | outline thickness in pixels (default 2) |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--vertices` | string | `""` | vertices as "n1,e1;n2,e2;..." (>= 3 absolute world-meter pairs) |
| `--vertices-file` | string | `""` | path to a file with one "north,east" per line (use for large polygons that hit Windows arg-length limits); mutually exclusive with --vertices |

---

[← CLI reference index](README.md)
