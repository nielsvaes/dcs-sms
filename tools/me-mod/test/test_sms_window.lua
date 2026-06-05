-- test_sms_window.lua — covers the pure helpers in sms_window.lua.
--
-- Pure helpers (testable without a real dxgui environment):
--   * _validate_severity(s) → skin name (with 'info' fallback)
--   * compose_title(title, version) → branded title string
--   * _new_flash_state() / _on_set_status / _on_flash_status / _on_tick
--     (the flash state machine — takes a fake clock)
--
-- The test runner walks tools/me-mod/test/test_*.lua. Failures abort
-- the run via assert(); successful tests print PASS lines.

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local sw = require('dcs_sms_me.sms_window')

-- ---------- _validate_severity ----------

assert(sw._validate_severity('info')    == 'staticSkin_ME',   "info -> staticSkin_ME")
print('PASS validate_severity(info) = staticSkin_ME')

assert(sw._validate_severity('success') == 'sms_status_green',  "success -> sms_status_green")
print('PASS validate_severity(success) = sms_status_green')

assert(sw._validate_severity('warning') == 'sms_status_yellow', "warning -> sms_status_yellow")
print('PASS validate_severity(warning) = sms_status_yellow')

assert(sw._validate_severity('error')   == 'sms_status_red',    "error -> sms_status_red")
print('PASS validate_severity(error) = sms_status_red')

-- Unknown severity falls back to info skin.
assert(sw._validate_severity('bogus') == 'staticSkin_ME', "unknown -> info fallback")
print('PASS validate_severity(bogus) = staticSkin_ME (info fallback)')

assert(sw._validate_severity(nil)     == 'staticSkin_ME', "nil -> info fallback")
print('PASS validate_severity(nil) = staticSkin_ME (info fallback)')

-- ---------- compose_title ----------

local got = sw.compose_title('Foo', '1.2.3')
assert(got == 'Coconut Cockpit · DCS-SMS — Foo v1.2.3',
       "compose_title basic: got " .. tostring(got))
print('PASS compose_title basic')

got = sw.compose_title('Prefab Manager', '0.5.0')
assert(got == 'Coconut Cockpit · DCS-SMS — Prefab Manager v0.5.0',
       "compose_title prefab manager: got " .. tostring(got))
print('PASS compose_title prefab manager')

-- ---------- flash state machine ----------

-- Fresh state has no sticky baseline and no flash expiry.
local s = sw._new_flash_state()
assert(s.sticky_text == nil)
assert(s.sticky_severity == nil)
assert(s.flash_expires_at == nil)
print('PASS flash state initial')

-- _on_set_status records sticky baseline + clears any pending flash.
local text, sev = sw._on_set_status(s, 'baseline', 'info')
assert(text == 'baseline')
assert(sev  == 'info')
assert(s.sticky_text     == 'baseline')
assert(s.sticky_severity == 'info')
assert(s.flash_expires_at == nil)
print('PASS on_set_status baseline')

-- _on_flash_status sets a timeout but does NOT mutate sticky baseline.
text, sev = sw._on_flash_status(s, 'flashing', 'success', 5, 1000)
assert(text == 'flashing')
assert(sev  == 'success')
assert(s.sticky_text     == 'baseline')
assert(s.sticky_severity == 'info')
assert(s.flash_expires_at == 1005)
print('PASS on_flash_status sets timeout, leaves sticky')

-- _on_tick before expiry returns nil (nothing to render).
local r = sw._on_tick(s, 1004)
assert(r == nil)
print('PASS on_tick before expiry returns nil')

-- _on_tick at or after expiry returns the sticky baseline + clears expiry.
text, sev = sw._on_tick(s, 1005)
assert(text == 'baseline')
assert(sev  == 'info')
assert(s.flash_expires_at == nil)
print('PASS on_tick at expiry reverts to sticky and clears expiry')

-- _on_tick on a state with no flash returns nil.
r = sw._on_tick(s, 9999)
assert(r == nil)
print('PASS on_tick with no flash returns nil')

-- _on_set_status during a flash cancels the flash.
sw._on_flash_status(s, 'will be cancelled', 'success', 5, 2000)
assert(s.flash_expires_at == 2005)
sw._on_set_status(s, 'new sticky', 'warning')
assert(s.flash_expires_at == nil)
assert(s.sticky_text     == 'new sticky')
assert(s.sticky_severity == 'warning')
print('PASS on_set_status during flash cancels flash')

-- _on_flash_status during a flash replaces the previous one (latest wins).
sw._on_flash_status(s, 'first', 'info', 5, 3000)
assert(s.flash_expires_at == 3005)
sw._on_flash_status(s, 'second', 'success', 10, 3001)
assert(s.flash_expires_at == 3011)  -- second's expiry, not first's
print('PASS flash replaces flash')

-- nil sticky baseline is OK — _on_tick reverts to empty / info defaults.
local s2 = sw._new_flash_state()
sw._on_flash_status(s2, 'flash with no baseline', 'success', 5, 100)
text, sev = sw._on_tick(s2, 105)
assert(text == '')
assert(sev  == 'info')
print('PASS on_tick reverts to empty/info when no sticky baseline')

print('All sms_window tests passed.')
