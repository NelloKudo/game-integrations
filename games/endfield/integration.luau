-- Endfield integration v0.2.0
-- Copyright (C) 2026 NelloKudo <marshnelloosu@gmail.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

--!nocheck

function import(...)
    return (load("import").value)(...)
end

type Variant = {
    platform: string,
    edition: string
}

type Pack = {
    url: string,
    md5: string,
    package_size: string
}

local __semver = nil

local function semver(version: string): any
    if not __semver then
        __semver = import("semver")
    end
    return __semver(version)
end

------------------------------------------------- Constants -------------------------------------------------

local BASE_URL = "https://launcher.gryphline.com"
local APP_CODE = "YDUTE5gscDZ229CW"
local UMU_VERSION = "1.3.0"
local PROTON_VERSION = "dwproton-10.0-22"
local PROTON_ARCHIVE_NAME = "dwproton-10.0-22-x86_64"
local PROTON_URL = "https://dawn.wine/dawn-winery/dwproton/releases/download/dwproton-10.0-22/dwproton-10.0-22-x86_64.tar.xz"

------------------------------------------------- Paths -------------------------------------------------

local data_dir_path: string = path.persist_dir("endfield")

local game_dir_path: string      = path.join(data_dir_path, "game")
local game_version_path: string  = path.join(game_dir_path, ".version")
local game_binary_path: string   = path.join(game_dir_path, "Endfield.exe")
local umu_dir_path: string       = path.join(data_dir_path, "umu")
local umu_binary_path: string    = path.join(umu_dir_path, "umu-run")
local proton_dir_path: string    = path.join(data_dir_path, "proton")
local proton_binary_path: string = path.join(proton_dir_path, PROTON_ARCHIVE_NAME, "files", "bin", "wine64")
local prefix_dir_path: string    = path.join(data_dir_path, "prefix")
local repair_flag_path: string   = path.join(data_dir_path, ".repair_requested")

------------------------------------------------- API Functions -------------------------------------------------

local function batch_proxy_post(body: {[string]: any}): ({[string]: any}?, string?)
    local url = `{BASE_URL}/api/proxy/batch_proxy`
    local json_str = str.encode("json", body)

    local response = http.fetch(url, {
        method = "post",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json"
        },
        body = str.to_bytes(json_str)
    }):await()

    if not response.is_ok then
        return nil, "HTTP request failed with status: " .. tostring(response.status)
    end

    local response_str = str.from_bytes(response.body)
    local decoded = str.decode("json", response_str)

    if not decoded then
        return nil, "Failed to parse JSON response"
    end

    return decoded, nil
end

local function get_latest_game_info(current_version: string?): ({version: string?, packs: {Pack}?, is_patch: boolean?}?, string?)
    local body = {
        proxy_reqs = {
            {
                kind = "get_latest_game",
                get_latest_game_req = {
                    appcode = APP_CODE,
                    channel = "6",
                    sub_channel = "6",
                    version = current_version or ""
                }
            }
        }
    }

    local response, err = batch_proxy_post(body)
    if err then
        return nil, err
    end

    if not response or not response.proxy_rsps then
        return nil, "Invalid API response"
    end

    for _, proxy_rsp in ipairs(response.proxy_rsps) do
        if proxy_rsp.get_latest_game_rsp then
            local game_rsp = proxy_rsp.get_latest_game_rsp

            if current_version and game_rsp.patch and game_rsp.patch.patches then
                local patches = {}
                for _, patch in ipairs(game_rsp.patch.patches) do
                    if patch.url and patch.url ~= "" then
                        table.insert(patches, patch)
                    end
                end

                if #patches > 0 then
                    return {
                        version = game_rsp.version,
                        packs = patches,
                        is_patch = true
                    }, nil
                end
            end

            if game_rsp.pkg and game_rsp.pkg.packs then
                return {
                    version = game_rsp.version,
                    packs = game_rsp.pkg.packs,
                    is_patch = false
                }, nil
            end
        end
    end

    return nil, "No game package found in API response"
end

------------------------------------------------- Command Wrapper -------------------------------------------------

local function parse_command_wrapper(wrapper: string, command: string, args: {string}, env: {[string]: string}?): (string, {string}, {[string]: string})
    if not wrapper or wrapper == "" then
        return command, args, env or {}
    end

    local parts = {}
    for part in string.gmatch(wrapper, "%S+") do
        table.insert(parts, part)
    end

    local new_command = command
    local new_args = clone(args)
    local new_env = env and clone(env) or {}
    local has_wrapper_command = false

    local wrapper_parts = {}
    for _, part in ipairs(parts) do
        if part == "%command%" then
            -- placeholder
        elseif string.match(part, "^[A-Z_][A-Z0-9_]*=") then
            local key, value = string.match(part, "^([^=]+)=(.*)$")
            if key and value then
                new_env[key] = value
            end
        else
            has_wrapper_command = true
            table.insert(wrapper_parts, part)
        end
    end

    if has_wrapper_command then
        new_command = wrapper_parts[1]

        local final_args = {}
        for i = 2, #wrapper_parts do
            table.insert(final_args, wrapper_parts[i])
        end

        table.insert(final_args, command)
        for _, arg in ipairs(args) do
            table.insert(final_args, arg)
        end

        new_args = final_args
    end

    return new_command, new_args, new_env
end

local function process_delete_files()
    local delete_file_path = path.join(game_dir_path, "delete_files.txt")

    if not fs.exists(delete_file_path) then
        return
    end

    local content = str.from_bytes(fs.read_file(delete_file_path):await())

    local remove_promises = {}

    for line in string.gmatch(content, "[^\r\n]+") do
        line = string.match(line, "^%s*(.-)%s*$")

        if line and line ~= "" then
            local file_to_delete = path.join(game_dir_path, line)

            if fs.exists(file_to_delete) then
                table.insert(remove_promises, fs.remove(file_to_delete))
            end
        end
    end

    for _, promise in ipairs(remove_promises) do
        local ok, err = pcall(function()
            promise:await()
        end)
        if not ok then
            print("Warning: failed to delete file: " .. tostring(err))
        end
    end

    local ok, err = pcall(function()
        fs.remove(delete_file_path):await()
    end)
    if not ok then
        print("Warning: failed to delete delete_files.txt: " .. tostring(err))
    end
end

------------------------------------------------- Version Management -------------------------------------------------

local function get_game_version(): string?
    if not fs.exists(game_version_path) then
        return nil
    end

    return str.from_bytes(fs.read_file(game_version_path):await())
end

local function set_game_version(version: string)
    fs.write_file(game_version_path, str.to_bytes(version)):await()
end

local function is_game_installed(): boolean
    local data_folder = path.join(game_dir_path, "Endfield_Data")
    return fs.exists(game_binary_path) and fs.exists(path.join(data_folder, "globalgamemanagers"))
end

------------------------------------------------- Component Management -------------------------------------------------

local function is_umu_installed(): boolean
    return fs.exists(umu_binary_path)
end

local function is_proton_installed(): boolean
    return fs.exists(proton_binary_path)
end

local function get_prefix_path(settings): string
    local prefix_name = settings.get_property("runner.prefix") or "endfield"
    return path.join(prefix_dir_path, prefix_name)
end

local function get_gameid(settings): string
    return settings.get_property("runner.gameid") or "umu-endfield"
end

------------------------------------------------- Progress Formatting -------------------------------------------------

local function format_progress(current: number, total: number, speed: number?)
    local current_mb = string.format("%.2f", current / 1024 / 1024)
    local total_mb   = string.format("%.2f", total   / 1024 / 1024)
    return `{current_mb} MB / {total_mb} MB`
end

local function format_extract_progress(current: number, total: number)
    local current_mb = string.format("%.2f", current / 1024 / 1024)
    local total_mb   = string.format("%.2f", total   / 1024 / 1024)
    return `{current_mb} MB / {total_mb} MB`
end

local function format_repair_progress(current: number, total: number, speed: number?)
    local current_mb = string.format("%.2f", current / 1024 / 1024)
    local total_mb   = string.format("%.2f", total   / 1024 / 1024)
    return `{current_mb} MB / {total_mb} MB`
end

local function make_speed_tracker()
    local last_bytes = 0
    local last_time = system.utc_time()
    local speed_bps = 0

    return function(current: number): number
        local now = system.utc_time()
        local dt = now - last_time

        if dt >= 1 then
            speed_bps = (current - last_bytes) / dt
            last_bytes = current
            last_time = now
        end

        return speed_bps
    end
end

------------------------------------------------- Repair -------------------------------------------------

-- extracts the cdn version-tag (segment 7) from a pack url
local function extract_version_tag(url: string): string?
    local cdn_path = string.match(url, "beyond%.hg%-cdn%.com(/.*)")
    if not cdn_path then return nil end

    local i = 0
    for part in string.gmatch(cdn_path, "[^/]+") do
        i = i + 1
        if i == 7 then
            return part
        end
    end

    return nil
end

-- fetches version, short_version and version_tag needed for repair urls
local function get_repair_info(): ({version: string, version_tag: string, short_version: string}?, string?)
    local body = {
        proxy_reqs = {
            {
                kind = "get_latest_game",
                get_latest_game_req = {
                    appcode = APP_CODE,
                    channel = "6",
                    sub_channel = "6",
                    version = ""
                }
            }
        }
    }

    local response, err = batch_proxy_post(body)
    if err then return nil, err end
    if not response or not response.proxy_rsps then
        return nil, "Invalid API response"
    end

    for _, proxy_rsp in ipairs(response.proxy_rsps) do
        if proxy_rsp.get_latest_game_rsp then
            local game_rsp = proxy_rsp.get_latest_game_rsp
            local version = game_rsp.version
            if not version then
                return nil, "No version in API response"
            end

            local sv = semver(version)
            local short_version = sv.major .. "." .. sv.minor

            local version_tag = nil

            if game_rsp.pkg then
                if game_rsp.pkg.packs then
                    for _, pack in ipairs(game_rsp.pkg.packs) do
                        version_tag = extract_version_tag(pack.url)
                        if version_tag then break end
                    end
                end
                if not version_tag and game_rsp.pkg.url then
                    version_tag = extract_version_tag(game_rsp.pkg.url)
                end
            end

            if not version_tag and game_rsp.patch then
                if game_rsp.patch.patches then
                    for _, patch in ipairs(game_rsp.patch.patches) do
                        version_tag = extract_version_tag(patch.url)
                        if version_tag then break end
                    end
                end
                if not version_tag and game_rsp.patch.url then
                    version_tag = extract_version_tag(game_rsp.patch.url)
                end
            end

            if not version_tag then
                return nil, "Could not extract version_tag from API response"
            end

            return {
                version = version,
                version_tag = version_tag,
                short_version = short_version
            }, nil
        end
    end

    return nil, "No game info in API response"
end

-- builds repair pipeline; state is shared between steps via upvalues
local function build_repair_pipeline()
    local repair_info      = nil
    local manifest_entries = {}
    local broken_files     = {}

    return {
        title = "Repair Endfield",
        pipeline = {
            {
                title = "Fetch version info",
                perform = function(updater)
                    updater({
                        current = 0, total = 0,
                        format = function() return "Fetching version info..." end
                    })

                    local info, err = get_repair_info()
                    if err or not info then
                        error("Failed to get repair info: " .. (err or "unknown"))
                    end

                    repair_info = info
                end
            },

            {
                title = "Download manifest",
                perform = function(updater)
                    updater({
                        current = 0, total = 0,
                        format = function() return `Fetching manifest for {repair_info.version}...` end
                    })

                    local url = `https://github.com/dawn-winery/p30k-manifest/releases/download/{repair_info.version}/manifest.tsv`
                    local resp = http.fetch(url, { method = "get" }):await()

                    if not resp.is_ok then
                        error(`Manifest download failed: HTTP {resp.status}`)
                    end

                    manifest_entries = {}
                    for line in string.gmatch(str.from_bytes(resp.body), "[^\r\n]+") do
                        line = string.match(line, "^%s*(.-)%s*$")
                        if line and line ~= "" then
                            local md5, filename = string.match(line, "^([^\t]+)\t(.+)$")
                            if md5 and filename then
                                table.insert(manifest_entries, { md5 = md5, filename = filename })
                            end
                        end
                    end

                    updater({
                        current = 1, total = 1,
                        format = function() return `Loaded {#manifest_entries} manifest entries` end
                    })
                end
            },

            {
                title = "Verify game files",
                perform = function(updater)
                    local total = #manifest_entries
                    broken_files = {}

                    -- throttle ui updates to avoid flooding the gtk message queue
                    local UPDATE_INTERVAL = 50

                    for i, entry in ipairs(manifest_entries) do
                        if i == 1 or i % UPDATE_INTERVAL == 0 or i == total then
                            updater({
                                current = i, total = total,
                                format = function()
                                    return `Verifying ({i}/{total}) {path.file_name(entry.filename) or entry.filename}`
                                end
                            })
                        end

                        local file_path = path.join(game_dir_path, entry.filename)

                        if not fs.exists(file_path) then
                            table.insert(broken_files, entry.filename)
                        else
                            local hash_bytes = hash.digitize_file("md5", file_path):await()
                            local actual_md5 = str.encode("hex", hash_bytes)
                            if string.lower(actual_md5) ~= string.lower(entry.md5) then
                                table.insert(broken_files, entry.filename)
                            end
                        end
                    end
                end
            },

            {
                title = "Repair game files",
                before = function()
                    return #broken_files > 0
                end,
                perform = function(updater)
                    local total = #broken_files
                    local dl_handle = downloader.create()

                    for i, filename in ipairs(broken_files) do
                        local file_url = `https://beyond.hg-cdn.com/{APP_CODE}/{repair_info.short_version}/update/6/6/Windows/{repair_info.version_tag}/files/{filename}`
                        local dest = path.join(game_dir_path, filename)

                        local parent = path.parent(dest)
                        if parent and not fs.exists(parent) then
                            fs.create_dir(parent):await()
                        end

                        local speed_tracker = make_speed_tracker()
                        local task = downloader.download(dl_handle, {
                            url = file_url,
                            output_file = dest,
                            continue_download = false,
                            on_update = function(current: number, file_total: number)
                                local speed = speed_tracker(current)
                                updater({
                                    current = current, total = file_total,
                                    format = function()
                                        return `Repairing ({i}/{total}) {path.file_name(filename) or filename}: {format_repair_progress(current, file_total, speed)}`
                                    end
                                })
                            end
                        })
                        downloader.wait(task)
                    end

                    downloader.close(dl_handle)
                end
            }
        }
    }
end

------------------------------------------------- Install / Update Pipelines -------------------------------------------------

local function build_umu_pipeline()
    local umu_archive_path = path.join(path.temp_dir(), `umu-launcher-{UMU_VERSION}.tar`)

    return {
        title = "Install umu-launcher",
        pipeline = {
            {
                title = "Download umu-launcher",
                perform = function(updater)
                    local speed_tracker = make_speed_tracker()
                    local downloader_handle = downloader.create()
                    local task_handle = downloader.download(downloader_handle, {
                        url = `https://github.com/Open-Wine-Components/umu-launcher/releases/download/{UMU_VERSION}/umu-launcher-{UMU_VERSION}-zipapp.tar`,
                        output_file = umu_archive_path,
                        continue_download = true,
                        on_update = function(current: number, total: number)
                            local speed = speed_tracker(current)
                            updater({
                                current = current, total = total,
                                format = function()
                                    return format_progress(current, total, speed)
                                end
                            })
                        end
                    })
                    downloader.wait(task_handle)
                    downloader.close(downloader_handle)
                end
            },
            {
                title = "Extract umu-launcher",
                perform = function(updater)
                    if fs.exists(umu_dir_path) then
                        fs.remove_dir(umu_dir_path):await()
                    end

                    fs.create_dir(data_dir_path):await()
                    local handle: number = archive.open(umu_archive_path)

                    archive.extract(handle, data_dir_path, function(current: number, total: number)
                        updater({
                            current = current, total = total,
                            format = function()
                                return format_extract_progress(current, total)
                            end
                        })
                    end)

                    archive.close(handle)
                    fs.remove(umu_archive_path):await()
                end
            }
        }
    }
end

local function build_proton_pipeline()
    local proton_archive_path = path.join(path.temp_dir(), `{PROTON_ARCHIVE_NAME}.tar.xz`)

    return {
        title = `Install {PROTON_ARCHIVE_NAME}`,
        pipeline = {
            {
                title = "Download Proton",
                perform = function(updater)
                    local speed_tracker = make_speed_tracker()
                    local downloader_handle = downloader.create()
                    local task_handle = downloader.download(downloader_handle, {
                        url = PROTON_URL,
                        output_file = proton_archive_path,
                        continue_download = true,
                        on_update = function(current: number, total: number)
                            local speed = speed_tracker(current)
                            updater({
                                current = current, total = total,
                                format = function()
                                    return format_progress(current, total, speed)
                                end
                            })
                        end
                    })
                    downloader.wait(task_handle)
                    downloader.close(downloader_handle)
                end
            },
            {
                title = "Extract Proton",
                perform = function(updater)
                    if fs.exists(proton_dir_path) then
                        fs.remove_dir(proton_dir_path):await()
                    end

                    fs.create_dir(proton_dir_path):await()
                    local handle: number = archive.open(proton_archive_path)

                    archive.extract(handle, proton_dir_path, function(current: number, total: number)
                        updater({
                            current = current, total = total,
                            format = function()
                                return format_extract_progress(current, total)
                            end
                        })
                    end)

                    archive.close(handle)
                    fs.remove(proton_archive_path):await()
                end
            }
        }
    }
end

local function build_update_pipeline(current_version: string?, game_info: {version: string?, packs: {Pack}?, is_patch: boolean?})
    local packs = game_info.packs
    local version = game_info.version or "unknown"
    local is_patch = game_info.is_patch or false
    local is_update = current_version ~= nil
    local download_type = is_patch and "patch" or "game"

    local steps = {}

    if not is_patch then
        table.insert(steps, {
            title = "Delete old files",
            before = function()
                return fs.exists(game_dir_path) and not is_update
            end,
            perform = function()
                fs.remove_dir(game_dir_path):await()
                fs.create_dir(game_dir_path):await()
            end
        })
    end

    table.insert(steps, {
        title = `Download {download_type} files ({#packs} parts)`,
        perform = function(updater)
            local speed_tracker = make_speed_tracker()
            local downloader_handle = downloader.create()
            local total_downloaded = 0
            local total_size = 0

            for _, pack in ipairs(packs) do
                total_size = total_size + (tonumber(pack.package_size) or 0)
            end

            for idx, pack in ipairs(packs) do
                local pack_path = path.join(path.temp_dir(), string.format("endfield_pack.zip.%03d", idx))
                local pack_size = tonumber(pack.package_size) or 0

                local task_handle = downloader.download(downloader_handle, {
                    url = pack.url,
                    output_file = pack_path,
                    continue_download = true,
                    on_update = function(current: number, total: number)
                        local effective_total = total_size > 0 and total_size or total
                        local global_current = total_downloaded + current
                        local speed = speed_tracker(global_current)
                        updater({
                            current = global_current,
                            total = effective_total,
                            format = function()
                                return format_progress(global_current, effective_total, speed)
                            end
                        })
                    end
                })
                downloader.wait(task_handle)

                total_downloaded = total_downloaded + pack_size
            end

            downloader.close(downloader_handle)
        end
    })

    table.insert(steps, {
        title = `Extract {download_type} files`,
        perform = function(updater)
            local total_size = 0
            for _, pack in ipairs(packs) do
                total_size = total_size + (tonumber(pack.package_size) or 0)
            end

            -- open only the first split part; the archive library reassembles the
            -- remaining parts (.zip.002, .zip.003, …) automatically
            local first_part_path = path.join(path.temp_dir(), "endfield_pack.zip.001")

            archive.extract(
                archive.open(first_part_path),
                game_dir_path,
                function(current: number, total: number, diff: number)
                    updater({
                        current = current,
                        total = total_size,
                        format = function()
                            return format_extract_progress(current, total_size)
                        end
                    })
                end
            )

            -- clean up all split parts
            for idx, _ in ipairs(packs) do
                local part_path = path.join(path.temp_dir(), string.format("endfield_pack.zip.%03d", idx))
                if fs.exists(part_path) then
                    fs.remove(part_path):await()
                end
            end
        end
    })

    if is_patch then
        table.insert(steps, {
            title = "Clean up old files",
            perform = function()
                process_delete_files()
            end
        })
    end

    table.insert(steps, {
        title = "Finalize installation",
        perform = function()
            set_game_version(version)
        end
    })

    local action_title
    if is_update then
        if is_patch then
            action_title = "Update Endfield (Patch)"
        else
            action_title = "Update Endfield (Full)"
        end
    else
        action_title = "Install Endfield"
    end

    return {
        title = action_title,
        pipeline = steps
    }
end

------------------------------------------------- Imports -------------------------------------------------

local __settings = nil

local function import_settings()
    if not __settings then
        __settings = import("settings")({
            game = "endfield",
            layout = {
                launcher = {
                    title = "Launcher",
                    entries = {
                        mangohud = {
                            title = "Enable MangoHud",
                            entry = {
                                format = "switch",
                                default = false
                            }
                        },
                        command_wrapper = {
                            title = "Command wrapper",
                            entry = {
                                format = "text",
                                default = ""
                            }
                        }
                    }
                },
                runner = {
                    title = "Runner Settings",
                    entries = {
                        gameid = {
                            title = "Game ID",
                            entry = {
                                format = "text",
                                default = "umu-endfield"
                            }
                        },
                        prefix = {
                            title = "Prefix name",
                            entry = {
                                format = "text",
                                default = "endfield"
                            }
                        }
                    }
                }
            }
        })
    end

    return __settings
end

------------------------------------------------- Module -------------------------------------------------

return function()
    return {
        game = {
            get_launch_info = function(variant: Variant)
                if not is_game_installed() then
                    return nil
                end

                if not is_umu_installed() or not is_proton_installed() then
                    return nil
                end

                -- hide play when update is available so update becomes the primary action
                local current_version = get_game_version()
                local game_info, _ = get_latest_game_info(current_version)
                if game_info and current_version ~= game_info.version then
                    return nil
                end

                local settings = import_settings()

                local proton_path = path.join(proton_dir_path, PROTON_ARCHIVE_NAME)
                local prefix_path = get_prefix_path(settings)

                if not fs.exists(prefix_path) then
                    fs.create_dir(prefix_path):await()
                end

                local launch_info = {
                    binary = umu_binary_path,
                    args = { game_binary_path },
                    env = {
                        PROTONPATH = proton_path,
                        WINEPREFIX = path.join(prefix_path, "pfx"),
                        GAMEID = get_gameid(settings),
                        PROTONFIXES_DISABLE = "1",
                        WINEDEBUG = ""
                    }
                }

                local current_binary = launch_info.binary
                local current_args = launch_info.args or {}
                local current_env = launch_info.env or {}

                local command_wrapper = settings.get_property("launcher.command_wrapper")
                if command_wrapper and command_wrapper ~= "" then
                    current_binary, current_args, current_env = parse_command_wrapper(
                        command_wrapper,
                        current_binary,
                        current_args,
                        current_env
                    )
                end

                if settings.get_property("launcher.mangohud") then
                    current_binary, current_args, current_env = parse_command_wrapper(
                        "mangohud %command%",
                        current_binary,
                        current_args,
                        current_env
                    )
                end

                launch_info.binary = current_binary
                launch_info.args = current_args
                launch_info.env = current_env

                return launch_info
            end,

            get_actions_pipeline = function(variant: Variant)
                if not is_umu_installed() then
                    return build_umu_pipeline()
                end

                if not is_proton_installed() then
                    return build_proton_pipeline()
                end

                local current_version = nil
                if is_game_installed() then
                    current_version = get_game_version()
                end

                local game_info, err = get_latest_game_info(current_version)
                if err then
                    error("Failed to get game info from API: " .. err)
                end

                if not game_info or not game_info.packs then
                    error("No download packs available")
                end

                -- update takes priority over repair
                if not current_version or current_version ~= game_info.version then
                    return build_update_pipeline(current_version, game_info)
                end

                -- game is up to date, check if repair was requested
                if fs.exists(repair_flag_path) then
                    fs.remove(repair_flag_path):await()
                    return build_repair_pipeline()
                end

                return nil
            end
        },

        settings = {
            get_property = function(name: string): any
                local settings = import_settings()
                return settings.get_property(name)
            end,

            set_property = function(name: string, value: any)
                local settings = import_settings()
                settings.set_property(name, value)
            end,

            get_layout = function(variant: Variant)
                local settings = import_settings()
                return settings.get_layout(variant)
            end
        },

        tools = {
            -- returns tool buttons shown in the launcher ui
            get_buttons = function(variant: Variant)
                if not is_game_installed() or not is_umu_installed() or not is_proton_installed() then
                    return {}
                end

                local settings = import_settings()
                local proton_path = path.join(proton_dir_path, PROTON_ARCHIVE_NAME)
                local prefix_path = get_prefix_path(settings)

                local wine_env = {
                    PROTONPATH = proton_path,
                    WINEPREFIX = path.join(prefix_path, "pfx"),
                    GAMEID = get_gameid(settings),
                    PROTONFIXES_DISABLE = "1",
                    WINEDEBUG = ""
                }

                return {
                    {
                        title = "Wine Configuration",
                        description = "Open winecfg to adjust Wine settings for Endfield",
                        callback = function()
                            process.open(umu_binary_path, { "winecfg" }, wine_env)
                        end
                    },

                    {
                        title = "Wine Console",
                        description = "Open an interactive Wine console inside the prefix",
                        callback = function()
                            process.open(umu_binary_path, { "wineconsole" }, wine_env)
                        end
                    },

                    {
                        title = "Remake Wine Prefix",
                        description = "Delete and reinitialise the Wine prefix (resets all Wine settings)",
                        callback = function()
                            portal.dialog({
                                title = "Remake Wine Prefix",
                                message = "This will permanently delete and recreate your Wine prefix.\n\nAll Wine registry entries, DLL overrides, and per-game settings will be lost.\n\nContinue?",
                                can_close = true,
                                buttons = {
                                    {
                                        label = "Remake Prefix",
                                        status = "dangerous",
                                        callback = function()
                                            if fs.exists(prefix_path) then
                                                fs.remove(prefix_path):await()
                                            end
                                            fs.create_dir(prefix_path):await()

                                            local handle = process.open(
                                                umu_binary_path,
                                                { "wineboot", "--init" },
                                                wine_env
                                            )
                                            process.wait(handle)

                                            portal.toast({ message = "Wine prefix recreated successfully" })
                                        end
                                    }
                                }
                            })
                        end
                    },

                    {
                        title = "Repair Game",
                        description = "Verify all game files against the upstream manifest and redownload any that are missing or corrupted",
                        callback = function()
                            -- write flag file so get_actions_pipeline returns repair pipeline on next cycle
                            fs.write_file(repair_flag_path, str.to_bytes("")):await()

                            portal.toast({
                                message = "Repair queued — click the action button to start",
                                action = {
                                    label = "Cancel",
                                    callback = function()
                                        if fs.exists(repair_flag_path) then
                                            fs.remove(repair_flag_path):await()
                                        end
                                    end
                                }
                            })
                        end
                    },

                    {
                        title = "Open Integration Folder",
                        description = "Open the Endfield integration folder in your file manager",
                        callback = function()
                            process.open("xdg-open", { data_dir_path }, {})
                        end
                    }
                }
            end
        }
    }
end
