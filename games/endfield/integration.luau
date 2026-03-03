-- Endfield integration v0.1.0
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

------------------------------------------------- Constants -------------------------------------------------

local BASE_URL = "https://launcher.gryphline.com"
local APP_CODE = "YDUTE5gscDZ229CW"
local UMU_VERSION = "1.3.0"
local PROTON_VERSION = "dwproton-10.0-16"
local PROTON_ARCHIVE_NAME = "dwproton-10.0-16-x86_64"
local PROTON_URL = "https://dawn.wine/dawn-winery/dwproton/releases/download/dwproton-10.0-16/dwproton-10.0-16-x86_64.tar.xz"

------------------------------------------------- Paths -------------------------------------------------

local data_dir_path: string = path.persist_dir("endfield")

local game_dir_path: string     = path.join(data_dir_path, "game")
local game_version_path: string = path.join(game_dir_path, ".version")
local game_binary_path: string  = path.join(game_dir_path, "Endfield.exe")
local umu_dir_path: string      = path.join(data_dir_path, "umu")
local umu_binary_path: string   = path.join(umu_dir_path, "umu-run")
local proton_dir_path: string   = path.join(data_dir_path, "proton")
local proton_binary_path: string = path.join(proton_dir_path, PROTON_ARCHIVE_NAME, "files", "bin", "wine64")
local prefix_dir_path: string   = path.join(data_dir_path, "prefix")

------------------------------------------------- API Functions -------------------------------------------------

local function batch_proxy_post(body: {[string]: any}): ({[string]: any}?, string?)
    local url = BASE_URL .. "/api/proxy/batch_proxy"
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
            
            -- Check for patch update first (if current_version was provided)
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
            
            -- Fallback to full download
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
            -- Placeholder
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
    
    for line in string.gmatch(content, "[^\r\n]+") do
        line = string.match(line, "^%s*(.-)%s*$") -- trim whitespace
        
        if line and line ~= "" then
            local file_to_delete = path.join(game_dir_path, line)
            
            if fs.exists(file_to_delete) then
                fs.remove(file_to_delete):await()
            end
        end
    end
    
    -- Remove the delete_files.txt itself
    fs.remove(delete_file_path):await()
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
                    },
                    stdout = path.join(data_dir_path, "game.log"),
                    stderr = path.join(data_dir_path, "game.log")
                }
                
                -- Apply command wrappers
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
                -- Helper function for progress formatting
                local function format_progress(current: number, total: number): string
                    local current_mb = current / 1024 / 1024
                    local total_mb = total / 1024 / 1024
                    return string.format("%.2f MB / %.2f MB", current_mb, total_mb)
                end
                
                -- Check for umu installation
                if not is_umu_installed() then
                    local umu_archive_path = path.join(path.temp_dir(), `umu-launcher-{UMU_VERSION}.tar`)
                    
                    return {
                        title = "Install umu-launcher",
                        pipeline = {
                            {
                                title = "Download umu-launcher",
                                perform = function(updater)
                                    local downloader_handle = downloader.create()
                                    local task_handle = downloader.download(downloader_handle, {
                                        url = `https://github.com/Open-Wine-Components/umu-launcher/releases/download/{UMU_VERSION}/umu-launcher-{UMU_VERSION}-zipapp.tar`,
                                        output_file = umu_archive_path,
                                        continue_download = true,
                                        on_update = function(current: number, total: number)
                                            updater({
                                                current = current,
                                                total = total,
                                                format = function()
                                                    return format_progress(current, total)
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
                                            current = current,
                                            total = total,
                                            format = function()
                                                return format_progress(current, total)
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

                -- Check for Proton installation
                if not is_proton_installed() then
                    local proton_archive_path = path.join(path.temp_dir(), `{PROTON_ARCHIVE_NAME}.tar.xz`)
                    
                    return {
                        title = `Install {PROTON_ARCHIVE_NAME}`,
                        pipeline = {
                            {
                                title = "Download Proton",
                                perform = function(updater)
                                    local downloader_handle = downloader.create()
                                    local task_handle = downloader.download(downloader_handle, {
                                        url = PROTON_URL,
                                        output_file = proton_archive_path,
                                        continue_download = true,
                                        on_update = function(current: number, total: number)
                                            updater({
                                                current = current,
                                                total = total,
                                                format = function()
                                                    return format_progress(current, total)
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
                                            current = current,
                                            total = total,
                                            format = function()
                                                return format_progress(current, total)
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
                
                -- Determine if we need to install or update
                local current_version = nil
                local is_update = false
                
                if is_game_installed() then
                    current_version = get_game_version()
                    if current_version then
                        is_update = true
                    end
                end

                -- Get download info from API (with current version for patch check)
                local game_info, err = get_latest_game_info(current_version)
                if err then
                    error("Failed to get game info from API: " .. err)
                end
                
                if not game_info or not game_info.packs then
                    error("No download packs available")
                end

                -- If installed and versions match, no update needed
                if is_update and current_version == game_info.version then
                    return nil
                end

                local packs = game_info.packs
                local version = game_info.version or "unknown"
                local is_patch = game_info.is_patch or false

                -- Build download pipeline
                local download_steps = {}
                
                -- Delete old files (only for fresh install, not patch)
                if not is_patch then
                    table.insert(download_steps, {
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

                -- Download files
                local download_type = is_patch and "patch" or "game"
                table.insert(download_steps, {
                    title = `Download {download_type} files ({#packs} parts)`,
                    perform = function(updater)
                        local downloader_handle = downloader.create()
                        local total_downloaded = 0
                        local total_size = 0
                        
                        -- Calculate total size
                        for _, pack in ipairs(packs) do
                            total_size = total_size + tonumber(pack.package_size)
                        end
                        
                        -- Download all parts
                        for idx, pack in ipairs(packs) do
                            local pack_path = path.join(path.temp_dir(), `endfield_pack_{idx}.zip`)
                            
                            local task_handle = downloader.download(downloader_handle, {
                                url = pack.url,
                                output_file = pack_path,
                                continue_download = true,
                                on_update = function(current: number, total: number)
                                    updater({
                                        current = total_downloaded + current,
                                        total = total_size,
                                        format = function()
                                            return format_progress(total_downloaded + current, total_size)
                                        end
                                    })
                                end
                            })
                            downloader.wait(task_handle)
                            
                            total_downloaded = total_downloaded + tonumber(pack.package_size)
                        end
                        
                        downloader.close(downloader_handle)
                    end
                })
                
                -- Extraction part
                table.insert(download_steps, {
                    title = `Extract {download_type} files`,
                    perform = function(updater)
                        -- Calculate total size for progress tracking
                        local total_size = 0
                        for _, pack in ipairs(packs) do
                            total_size = total_size + tonumber(pack.package_size)
                        end
                        
                        local bytes_extracted = 0
                        
                        -- Extract each part sequentially
                        for idx, pack in ipairs(packs) do
                            local pack_path = path.join(path.temp_dir(), `endfield_pack_{idx}.zip`)
                            local pack_size = tonumber(pack.package_size)
                            
                            local part_start = bytes_extracted
                            local last_update = 0
                            
                            archive.extract(
                                archive.open(pack_path),
                                game_dir_path,
                                function(current: number, total: number, diff: number)
                                    local overall_current = part_start + current
                                    
                                    updater({
                                        current = overall_current,
                                        total = total_size,
                                        format = function()
                                            return `Part {idx}/{#packs}: {format_progress(overall_current, total_size)}`
                                        end
                                    })
                                    
                                    last_update = current
                                end
                            )
                            
                            bytes_extracted = bytes_extracted + pack_size
                            
                            -- Update to show part completed
                            updater({
                                current = bytes_extracted,
                                total = total_size,
                                format = function()
                                    return `Part {idx}/{#packs}: {format_progress(bytes_extracted, total_size)}`
                                end
                            })
                            
                            -- Remove the part after extraction
                            fs.remove(pack_path):await()
                        end
                    end
                })

                -- Process delete_files.txt (for patches)
                if is_patch then
                    table.insert(download_steps, {
                        title = "Clean up old files",
                        perform = function()
                            process_delete_files()
                        end
                    })
                end

                -- Write version file
                table.insert(download_steps, {
                    title = "Finalize installation",
                    perform = function()
                        set_game_version(version)
                    end
                })

                local action_title = is_update and (is_patch and "Update Endfield (Patch)" or "Update Endfield (Full)") or "Install Endfield"
                
                return {
                    title = action_title,
                    pipeline = download_steps
                }
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
        }
    }
end
