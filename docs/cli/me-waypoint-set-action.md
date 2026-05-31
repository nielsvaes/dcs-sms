# `dcs-sms me waypoint set-action`

[← CLI reference index](README.md)

set a waypoint's action (sms.waypoint.ACTION enum)

## Usage

```
dcs-sms me waypoint set-action [flags]
```

## Flags

| Name | Type | Default | Description |
|---|---|---|---|
| `--action` | string | `""` | waypoint action — how the unit traverses or arrives. Legal: AIR: "Turning Point", "Fly Over Point", "From Parking Area", "From Parking Area Hot", "From Ground Area", "From Ground Area Hot", "From Runway", "Landing", "LandingReFuAr". GROUND/SHIP TRAVERSAL: "Off Road", "On Road", "On Railroads". GROUND FORMATIONS (all need --type="Turning Point"): "Rank" (line abreast), "Cone", "Vee", "Diamond", "EchelonL", "EchelonR", "Custom" (pairs with --formation-template <saved-template-name>). NOTE: an airfield action sets the paired waypoint type (e.g. "From Parking Area" -> TakeOffParking) but does NOT bind a field — follow with `me waypoint link-airbase` to set the airdrome and place the units. |
| `--group-id` | int | `0` | group id (mutually exclusive with --group-name) |
| `--group-name` | string | `""` | group name (mutually exclusive with --group-id) |
| `--index` | int | `-1` | waypoint index (0-based; required) |
| `--pretty` | bool | `false` | indent JSON output |
| `--saved-games` | string | `""` | override Saved Games path |
| `--timeout` | duration | `30s` | wall-clock timeout |

---

[← CLI reference index](README.md)
