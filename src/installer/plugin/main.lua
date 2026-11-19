-- WeRead 1.8.8 for Kobo Libra 2 / Libra Colour: installer and launcher entry.
-- Not installed yet: the menu offers the installation (payload/install.sh,
-- run in the background, progress shown from install.progress). Installed
-- (/mnt/onboard/.adds/kobo-weread-home/installed): the launcher menu from
-- resident-v188/plugin-main-resident.lua, plus removing the installation files
-- and uninstalling.
local Device = require("device")
if not Device:isKobo() then return { disabled = true } end
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PluginShare = require("pluginshare")
local logger = require("logger")

local base = "/mnt/onboard/.adds/kobo-weread-home/"
local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local value = f:read("*a")
    f:close()
    return value
end
local function exists(path) return read(path) ~= nil end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function dirOf()
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*)/[^/]*$") or "."
    if dir:sub(1, 1) ~= "/" then
        local lfs = require("libs/libkoreader-lfs")
        dir = lfs.currentdir() .. "/" .. dir:gsub("^%./", "")
    end
    return dir
end
local plugin_dir = dirOf()

-- Size of the payload directory in MB (shown before removing it).
local function payloadMB()
    local p = io.popen("du -sk " .. q(plugin_dir .. "/payload") .. " 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local kb = tonumber(out:match("^(%d+)"))
    return kb and math.floor(kb / 1024) or 0
end

local function removePayload()
    UIManager:show(ConfirmBox:new {
        text = "删除安装包（约 " .. payloadMB() .. " MB）？\n\n已安装的微信读书不受影响；以后要重新安装需再次复制安装包。",
        ok_text = "删除",
        ok_callback = function()
            local ok = os.execute("rm -rf " .. q(plugin_dir .. "/payload"))
            UIManager:show(InfoMessage:new { text = ok == 0 and "安装包已删除。" or "删除失败。", timeout = 4 })
        end,
    })
end

local function uninstall(state_of)
    local state = state_of and state_of() or "none"
    if state ~= "none" then
        UIManager:show(InfoMessage:new { text = "请先在菜单里关闭后台 Android。", timeout = 5 })
        return
    end
    UIManager:show(ConfirmBox:new {
        text = "卸载微信读书？\n\n将删除 " .. base .. "（含 2 GB 镜像、登录状态和已下载的书），不能恢复。安装包保留时可以重新安装。",
        ok_text = "卸载",
        ok_callback = function()
            local ok = os.execute("grep -q ' /tmp/kobo-android-runtime ' /proc/mounts && exit 3; rm -rf " .. q(base:sub(1, -2)))
            UIManager:show(InfoMessage:new {
                text = ok == 0 and "已卸载。重启 KOReader 后菜单恢复为安装入口。" or "卸载失败：Android 仍在运行或文件被占用。",
                timeout = 6,
            })
        end,
    })
end

-- Not installed: the installer.
local Installer = WidgetContainer:extend { name = "wereadkobo", is_doc_only = false }
local progress_file = plugin_dir .. "/install.progress"
local state_file = plugin_dir .. "/install.state"

local function installState()
    local s = read(state_file)
    if not s then return "none" end
    local kind, code, text = s:match("^(%a+)%s*(%d*)%s*(.-)%s*$")
    return kind or "none", tonumber(code), text
end
-- "running" may be left from a run cut off by a reset or power loss: check
-- that an install.sh of this plugin is still alive.
local function installerAlive()
    local pid = (read(plugin_dir .. "/install.pid") or ""):match("^(%d+)")
    local cmdline = pid and read("/proc/" .. pid .. "/cmdline") or ""
    return cmdline:find("install.sh", 1, true) ~= nil
end
local function readProgress()
    local s = read(progress_file) or ""
    local step, steps, pct, text = s:match("^(%d+) (%d+) (%d+) ([^\n]*)")
    return tonumber(step), tonumber(steps), tonumber(pct) or 0, text
end

function Installer:init()
    self.ui.menu:registerToMainMenu(self)
    if installState() == "running" and installerAlive() then self:watch(true) end
end

function Installer:holdAwake(on)
    if on and not self.awake then
        self.awake = { previous = PluginShare.pause_auto_suspend }
        PluginShare.pause_auto_suspend = true
    elseif not on and self.awake then
        PluginShare.pause_auto_suspend = self.awake.previous
        self.awake = nil
    end
end

function Installer:closeDialog()
    if self.dialog then
        self.closing = true
        self.dialog:close()
        self.dialog = nil
        self.closing = false
    end
end

-- Progress: one dialog per step (its subtitle is fixed), the bar updated
-- every 2 s. Tapping it hides it; the installation goes on and the menu
-- entry shows it again.
function Installer:watch(show)
    self.visible = show
    self:holdAwake(true)
    if self.task then UIManager:unschedule(self.task) end
    self.task = function()
        local kind, code, text = installState()
        local step, steps, pct, ptext = readProgress()
        if kind == "running" and not installerAlive() then
            kind, code, text = "failed", 99, "安装进程意外结束（详见 install.log）"
        end
        if kind ~= "running" then
            self:closeDialog()
            self:holdAwake(false)
            self.task = nil
            if kind == "done" then
                UIManager:show(ConfirmBox:new {
                    text = self.upgrade and "升级完成。现在重启 KOReader？" or "微信读书 1.8.8 安装完成。\n\n重启 KOReader 后，在“工具”菜单的“微信读书 1.8.8（安装版）”里启动。第一次启动约需 2 分钟，之后同意协议并扫码登录。\n\n现在重启 KOReader？",
                    ok_text = "重启",
                    ok_callback = function() UIManager:restartKOReader() end,
                })
            else
                UIManager:show(InfoMessage:new { text = "安装失败（错误 " .. tostring(code) .. "）：\n" .. (text or "") .. "\n\n日志：" .. plugin_dir .. "/install.log" })
            end
            return
        end
        if self.visible then
            local title = step and ("正在安装微信读书 1.8.8（第 " .. step .. "/" .. steps .. " 步）") or "正在安装微信读书 1.8.8"
            -- The subtitle is one line: the step, then the one rule that matters.
            local subtitle = (ptext or "准备中") .. "　勿断电、勿连 USB"
            if not self.dialog or self.dialog_step ~= step then
                self:closeDialog()
                self.dialog = ProgressbarDialog:new {
                    title = title, subtitle = subtitle, progress_max = 100, refresh_time_seconds = 2,
                    dismiss_callback = function()
                        if not self.closing then self.visible = false; self.dialog = nil end
                    end,
                }
                self.dialog_step = step
                self.dialog:show()
            end
            self.dialog:reportProgress(pct)
        end
        UIManager:scheduleIn(2, self.task)
    end
    self.task()
end

function Installer:start(upgrade)
    self.upgrade = upgrade
    if installState() == "running" and installerAlive() then self:watch(true) return end
    if not exists(plugin_dir .. "/payload/install.sh") then
        UIManager:show(InfoMessage:new { text = "安装包不完整：缺少 payload 目录。请把整个 wereadkobo.koplugin 文件夹复制到 koreader/plugins。", timeout = 8 })
        return
    end
    UIManager:show(ConfirmBox:new {
        text = upgrade and "原地升级微信读书 1.8.8？请先关闭后台 Android。升级保留现有阅读数据、设置、截图和加速文件。" or "安装微信读书 1.8.8（Android 7 运行环境）？\n\n· 需要约 2.3 GB 存储空间，大约 5–10 分钟\n· 安装期间请接上电源，不要连接 USB 传输文件，也不要关机\n· 进度条点按可隐藏，安装继续；菜单“查看安装进度”可再显示\n· 安装完成后重启 KOReader 即可使用",
        ok_text = upgrade and "升级" or "安装",
        ok_callback = function()
            os.remove(state_file); os.remove(progress_file); os.remove(plugin_dir .. "/install.pid")
            local cmd = "/usr/bin/setsid " .. q(plugin_dir .. "/payload/fd-clean-exec") .. " /bin/sh " .. q(plugin_dir .. "/payload/install.sh") .. " " .. q(plugin_dir)
                .. " </dev/null >" .. q(plugin_dir .. "/install.log") .. " 2>&1 &"
            logger.info("wereadkobo: starting installer", cmd)
            os.execute(cmd)
            UIManager:scheduleIn(1, function() self:watch(true) end)
        end,
    })
end

function Installer:addToMainMenu(items)
    items.weread_kobo = {
        text = "微信读书 1.8.8（安装）",
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = "安装微信读书 1.8.8", callback = function() self:start() end },
            { text = "查看安装进度", callback = function()
                if installState() == "running" and installerAlive() then self:watch(true)
                else
                    local kind, code, text = installState()
                    local msg = kind == "failed" and ("上次安装失败（错误 " .. tostring(code) .. "）：" .. (text or "")) or kind == "done" and "已安装，请重启 KOReader。" or "尚未开始安装。"
                    UIManager:show(InfoMessage:new { text = msg, timeout = 6 })
                end
            end },
            { text = "说明", callback = function()
                UIManager:show(InfoMessage:new { text = "适用于 Kobo Libra 2（固件 4.34.20097 或 4.38.23852）或 Libra Colour（固件 4.42.23303）上的 KOReader。安装后在本菜单启动 Android 启动器，再打开微信读书。\n\n安装位置：" .. base .. "\n微信读书需要联网，首次使用要同意协议并用微信扫码登录。", timeout = 20 })
            end },
        },
    }
end

-- Installed: the launcher module, with two extra menu entries.
if exists(base .. "installed") then
    local ok, mod = pcall(dofile, base .. "resident-v188/plugin-main-resident.lua")
    if ok and type(mod) == "table" and mod.addToMainMenu then
        local launcher_menu = mod.addToMainMenu
        function mod:addToMainMenu(items)
            launcher_menu(self, items)
            local entry = items.weread_kobo
            if not entry then return end
            local ctl = base .. "resident-v188/resident-ctl.sh"
            local function state()
                local p = io.popen("/bin/sh " .. ctl .. " status 2>/dev/null")
                local v = p and p:read("*l") or "none"
                if p then p:close() end
                return v
            end
            entry.sub_item_table[#entry.sub_item_table].separator = true
            if exists(plugin_dir .. "/payload/install.sh") then
                table.insert(entry.sub_item_table, { text = "原地升级", callback = function() Installer:start(true) end })
                table.insert(entry.sub_item_table, { text = "删除安装包（释放空间）", callback = removePayload })
            end
            table.insert(entry.sub_item_table, { text = "卸载", callback = function() uninstall(state) end })
        end
        return mod
    end
    logger.warn("wereadkobo: launcher failed to load", mod)
end

return Installer
