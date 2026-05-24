# `dcs-sms me drawing create-line`

[← CLI reference index](README.md)

draw a polyline on the F10 map (segments / segment / free; --closed wraps it)

## Usage

```
dcs-sms me drawing create-line [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--closed` | bool | `false` | close the polyline back to the first vertex |
| `--color` | string | `""` | line color (default red, opaque) |
| `--hidden-on-planner` | bool | `false` | hide on mission planner |
| `--layer` | string | `""` | Red\|Blue\|Neutral\|Common\|Author (default Common) |
| `--line-mode` | string | `""` | segments \| segment \| free (default segments) |
| `--name` | string | `""` | drawing name (auto-allocated if empty) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--style` | string | `""` | line style (default solid) |
| `--thickness` | float | `0` | line thickness in pixels (default 2) |
| `--timeout` | duration | `30s` | wall-clock timeout |
| `--vertices` | string | `""` | vertices as "n1,e1;n2,e2;..." (>= 2 absolute world-meter pairs) |
| `--vertices-file` | string | `""` | path to a file with one "north,east" per line (use for long polylines that hit Windows arg-length limits); mutually exclusive with --vertices |

---

[← CLI reference index](README.md)
