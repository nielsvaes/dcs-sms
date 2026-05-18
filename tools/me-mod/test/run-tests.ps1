# Locates a Lua 5.1 interpreter on PATH and runs all me-mod unit tests:
#   - test_serializer.lua
#   - test_serializer_parity.lua
#   - test_distill_parity.lua
# Exits non-zero on any test failure or when no interpreter is available.

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSCommandPath
Push-Location $here
try {
    $candidates = @('lua.exe', 'lua5.1.exe', 'lua51.exe')
    $lua = $null
    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $lua = $cmd.Source; break }
    }
    if (-not $lua) {
        Write-Host 'No Lua 5.1 interpreter found on PATH.' -ForegroundColor Yellow
        Write-Host 'Tried:' ($candidates -join ', ')
        Write-Host ''
        Write-Host 'To run these tests, install a Lua 5.1 interpreter and put it on PATH.'
        Write-Host 'Recommended for Windows: https://luabinaries.sourceforge.net/'
        exit 2
    }
    Write-Host "Using Lua interpreter: $lua"
    $tests = @('test_airbase_detect.lua', 'test_context_menu_clipboard.lua', 'test_distill_parity.lua', 'test_filter_rows.lua', 'test_marquee_hook.lua', 'test_mass_edit_find_replace_group_name.lua', 'test_mass_edit_forms.lua', 'test_mass_edit_rename_group.lua', 'test_mass_edit_set_country.lua', 'test_mass_edit_transforms.lua', 'test_me_refresh.lua', 'test_paths_folder.lua', 'test_prefab_ops_airbases.lua', 'test_prefab_ops_delete_folder.lua', 'test_prefab_ops_folder_validate.lua', 'test_prefab_ops_load.lua', 'test_prefab_ops_move.lua', 'test_prefab_ops_place.lua', 'test_prefab_ops_rename_file.lua', 'test_prefab_ops_rename_folder.lua', 'test_prefab_ops_save.lua', 'test_prefab_ops_scan_migrate.lua', 'test_prefab_ops_scan_recursive.lua', 'test_selection_drilled.lua', 'test_selection_snapshot_mission.lua', 'test_serializer.lua', 'test_serializer_parity.lua', 'test_ship_warehouse.lua', 'test_skin_helper.lua', 'test_sms_window.lua', 'test_undo.lua', 'test_warehouse_ops.lua', 'test_verbs_route.lua')
    $anyFailed = $false
    foreach ($t in $tests) {
        if (-not (Test-Path $t)) { continue }
        Write-Host ""
        Write-Host "=== $t ===" -ForegroundColor Cyan
        & $lua $t
        if ($LASTEXITCODE -ne 0) { $anyFailed = $true }
    }
    if ($anyFailed) { exit 1 } else { exit 0 }
} finally {
    Pop-Location
}
