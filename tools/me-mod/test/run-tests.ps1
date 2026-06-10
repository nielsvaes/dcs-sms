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
    $tests = @('test_airbase_detect.lua', 'test_base64.lua', 'test_bridge_gen_counter.lua', 'test_community_cache.lua', 'test_community_config.lua', 'test_community_fetch.lua', 'test_community_import.lua', 'test_community_manifest.lua', 'test_community_tab_import.lua', 'test_community_transport.lua', 'test_context_menu_clipboard.lua', 'test_distill_parity.lua', 'test_filter_rows.lua', 'test_group_name_writer.lua', 'test_hotkey_actions.lua', 'test_hotkey_backend.lua', 'test_hotkey_config.lua', 'test_hotkey_engine.lua', 'test_hotkey_scripts.lua', 'test_lib_path.lua', 'test_marquee_hook.lua', 'test_mass_edit_add_prefix_group_name.lua', 'test_mass_edit_add_prefix_unit_name.lua', 'test_mass_edit_add_suffix_group_name.lua', 'test_mass_edit_add_suffix_unit_name.lua', 'test_mass_edit_airbase_marquee.lua', 'test_mass_edit_auto_name_unit.lua', 'test_mass_edit_auto_name_units_group.lua', 'test_mass_edit_export_import_warehouse_airbase.lua', 'test_mass_edit_find_replace_group_name.lua', 'test_mass_edit_find_replace_unit_name.lua', 'test_mass_edit_forms.lua', 'test_mass_edit_map_sync.lua', 'test_mass_edit_rename_group.lua', 'test_mass_edit_selection_status.lua', 'test_mass_edit_set_coalition_airbase.lua', 'test_mass_edit_set_country.lua', 'test_mass_edit_set_fuel_pct_unit.lua', 'test_mass_edit_set_heading_unit.lua', 'test_mass_edit_set_livery_unit.lua', 'test_mass_edit_set_onboard_num_unit.lua', 'test_mass_edit_set_skill_unit.lua', 'test_mass_edit_toggle_group_flags.lua', 'test_mass_edit_transforms.lua', 'test_me_camera.lua', 'test_me_group_focus.lua', 'test_me_refresh.lua', 'test_me_select_writer.lua', 'test_paths_folder.lua', 'test_prefab_naming.lua', 'test_prefab_ops_airbases.lua', 'test_prefab_ops_community_author.lua', 'test_prefab_ops_delete_folder.lua', 'test_prefab_ops_folder_validate.lua', 'test_prefab_ops_load.lua', 'test_prefab_ops_move.lua', 'test_prefab_ops_place.lua', 'test_prefab_ops_rename_file.lua', 'test_prefab_ops_rename_folder.lua', 'test_prefab_ops_save.lua', 'test_prefab_ops_scan_migrate.lua', 'test_prefab_ops_scan_recursive.lua', 'test_prefab_ops_triggers.lua', 'test_prefab_safe_load.lua', 'test_selection_drilled.lua', 'test_selection_snapshot_airbases.lua', 'test_selection_snapshot_mission.lua', 'test_serializer.lua', 'test_serializer_parity.lua', 'test_ship_warehouse.lua', 'test_skin_helper.lua', 'test_sms_scrollbars.lua', 'test_sms_window.lua', 'test_splitter.lua', 'test_trigger_export.lua', 'test_trigger_import.lua', 'test_trigger_media.lua', 'test_trigger_schema.lua', 'test_tri_state_button.lua', 'test_undo.lua', 'test_unit_applicability.lua', 'test_vendor_json.lua', 'test_verbs_aggregator.lua', 'test_verbs_airbase.lua', 'test_verbs_camera.lua', 'test_verbs_coords.lua', 'test_verbs_drawing.lua', 'test_verbs_file.lua', 'test_verbs_group.lua', 'test_verbs_resources.lua', 'test_verbs_route.lua', 'test_verbs_trigger.lua', 'test_verbs_unit.lua', 'test_verbs_waypoint_tasks.lua', 'test_verbs_zone.lua', 'test_warehouse_ops.lua')
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
