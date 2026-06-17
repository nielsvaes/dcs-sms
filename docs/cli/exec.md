# `dcs-sms exec`

[← CLI reference index](README.md)

execute a Lua snippet. --target gui runs it in the Mission Editor env (open the ME and toggle DCS-SMS → External execution ON first); --target mission runs it in a live mission; auto picks based on DCS state. Returns JSON with return_value (the snippet's return), output (captured print), and error.

## Usage

```
dcs-sms exec [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--code` | string | `""` | Lua code (inline) |
| `--file` | string | `""` | path to a .lua file |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--target` | string | `auto` | execution target: mission (live mission scripting env) \| gui (Mission Editor env — full DCS modules like magvar/Terrain, reads/writes the open mission) \| auto |
| `--timeout` | duration | `5s` | wall-clock timeout |
| `--wait` | bool | `false` | if hook isn't ready, poll until it is or --timeout elapses |

## Examples

```
dcs-sms exec --target mission --code "return Unit.getByName('Alpha-1'):getCoalition()"
```

```
# Mission Editor: any DCS module the ME has, e.g. magnetic declination at a lat/lon
```

```
dcs-sms exec --target gui --code "return require('magvar').get_mag_decl(51.556, -0.419)"
```

```
# (for magvar specifically, prefer the typed wrapper: dcs-sms me coords magvar --lat 51.556 --lon -0.419)
```

---

[← CLI reference index](README.md)
