# `dcs-sms me drawing create-circle`

[← CLI reference index](README.md)

draw a circle on the F10 map

## Usage

```
dcs-sms me drawing create-circle [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--color` | string | `""` | outline color: name, #rrggbb (alpha=0xff), #rrggbbaa, or 0xRRGGBBAA |
| `--east` | float | `0` | meters east of theatre origin |
| `--fill-color` | string | `""` | fill color: name, #rrggbb (alpha=0x80), #rrggbbaa, or 0xRRGGBBAA |
| `--hidden-on-planner` | bool | `false` | hide on mission planner |
| `--layer` | string | `""` | layer: Red\|Blue\|Neutral\|Common\|Author (default Common) |
| `--name` | string | `""` | drawing name (auto-allocated if empty) |
| `--north` | float | `0` | meters north of theatre origin |
| `--pretty` | bool | `false` | indent JSON output |
| `--radius` | float | `0` | radius in meters |
| `--saved-games` | string | `""` | override Saved Games path |
| `--style` | string | `""` | line style: solid\|solid2\|dot\|dot2\|dotdash\|dash\|cross\|square\|strongpoint\|triangle\|wirefence\|boundry1..5 (default solid) |
| `--thickness` | float | `0` | outline thickness in pixels (default 2) |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
