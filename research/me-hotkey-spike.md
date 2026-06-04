# ME Hotkeys — live-ME spike

Run with the ME open and **DCS-SMS → External execution: ON**. Use
`dcs-sms exec --target gui --code '<lua>'`. Records which engine backend to use.

## Q1 — per-key replace vs stack
```lua
local w = require('me_toolbar').window
w:addHotKeyCallback('a', function() log.write('sms.me.spike', log.INFO, 'PROBE a') end)
return 'attached probe to a — now press a in the ME and check dcs.log + whether the airplane tool still opens'
```
- Airplane tool still opens → **stack** (both fire). Airplane tool does NOT open → **replace** (last-wins).

## Q2 — global chokepoint suppression
```lua
local Gui = require('dxgui')
Gui.AddKeyboardCallback(function(keyName, keyState)
  log.write('sms.me.spike', log.INFO, 'KEY '..tostring(keyName)..' '..tostring(keyState))
end)
return 'logging all key events — press keys, check dcs.log; note whether ED actions still fire'
```

## Q3 — clean removal
```lua
local w = require('me_toolbar').window
local fn = function() log.write('sms.me.spike', log.INFO, 'PROBE2') end
w:addHotKeyCallback('p', fn)
w:removeHotKeyCallback('p', fn)
return 'attached then removed p — press p; PROBE2 should NOT log'
```

## Q4 — single-letter vs text input (make-or-break)
```lua
local w = require('me_toolbar').window
w:addHotKeyCallback('m', function() log.write('sms.me.spike', log.INFO, 'PROBE m') end)
return 'now open a unit name field and type a word with m — does it type normally or fire PROBE m?'
```

## Decision
| Q1 | Q2 | Backend | Native-override quality |
|---|---|---|---|
| replace | — | `perkey` (default) | clean |
| stack | suppress works | `global` | clean |
| stack | no suppress | `global`, additive | best-effort (ED key also fires) |

If the decision is `global`, set `M.BACKEND_MODE = 'global'` in
`tools/me-mod/lua/dcs_sms_me/me_hotkey_config.lua`.
