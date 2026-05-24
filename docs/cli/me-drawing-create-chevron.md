# `dcs-sms me drawing create-chevron`

[← CLI reference index](README.md)

draw a V-shape chevron / directional tick mark on the F10 map

## Usage

```
dcs-sms me drawing create-chevron [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--arm-angle` | float | `100` | angle of each arm from the forward bearing, in degrees (0,180). 100=wide V (160° tip — good for route ticks), 150=tight arrowhead (60° tip) |
| `--bearing` | float | `0` | tip bearing in degrees (0=N, 90=E, clockwise) — the direction the V points |
| `--color` | string | `""` | line color: name, #rrggbb, #rrggbbaa, or 0xRRGGBBAA (default red, opaque) |
| `--east` | float | `0` | meters east (chevron tip) |
| `--hidden-on-planner` | bool | `false` | hide on mission planner |
| `--layer` | string | `""` | Red\|Blue\|Neutral\|Common\|Author (default Common) |
| `--name` | string | `""` | drawing name (auto-allocated if empty) |
| `--north` | float | `0` | meters north (chevron tip) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--size` | float | `0` | arm length in meters (each arm extends this far back from the tip) |
| `--style` | string | `""` | line style (default solid) |
| `--thickness` | float | `0` | line thickness in pixels (default 2) |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
