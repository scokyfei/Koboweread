-- WeRead 1.9.7 launcher entry: a copy of the 1.9.8 plugin (wereadlibra2)
-- with its own files (resident-v197/, v197-launch.state); see resident-v197/.
local Device = require("device")
if not Device:isKobo() then return { disabled = true } end
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PluginShare = require("pluginshare")
local logger = require("logger")
local WeReadLab = WidgetContainer:extend { name = "wereadv197", is_doc_only = false }
local base = "/mnt/onboard/.adds/kobo-android-lab/"
local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local value = f:read("*a")
    f:close()
    return value
end
local function stage()
    local value = read(base .. "v197-launch.state")
    return value and value:match("^stage=([%a_]+)\n") or "none"
end
local function controllerAlive()
    local owner = read(base .. "weread-launch.lock/owner")
    if not owner then return false end
    local pid, started, boot = owner:match("^(%d+)%s+(%d+)%s+([%x%-]+)%s*$")
    if not pid then return false end
    local current_boot = read("/proc/sys/kernel/random/boot_id")
    if not current_boot or current_boot:match("^(%S+)") ~= boot then return false end
    local stat = read("/proc/" .. pid .. "/stat")
    local tail = stat and stat:match("^%d+ %b() (.*)")
    if not tail then return false end
    local fields = {}
    for word in tail:gmatch("%S+") do fields[#fields+1] = word end
    return fields[1] ~= "Z" and fields[20] == started
end
local messages = {
    none = "尚未从此菜单运行微信读书。",
    starting = "微信读书正在启动，通常需要几分钟。",
    running = "微信读书正在运行。",
    restoring = "正在恢复 KOReader。",
    complete = "上次运行已正常结束并返回。",
    background = "Android 在后台常驻。从菜单“Android 启动器”进入无需重新启动。",
    failed = "上次启动或运行未完成，请保留设备上的诊断记录。",
}
local phases = {
    runtime_begin = "正在准备运行环境。",
    framework_begin = "正在启动 Android 系统。",
    app_launch_begin = "正在准备打开微信读书。",
    resident_home_ready = "Android 启动器已就绪，正在接入显示。",
    interactive_ready = "界面已显示，正在接入触控。",
}
local failures = {
    [10] = "阅读环境初始化未完成。",
    [57] = "微信读书发生崩溃。",
    [61] = "微信读书未能在等待时间内显示界面。",
    [110] = "联网诊断未通过。",
    [114] = "阅读触控尚未就绪。",
    [117] = "微信读书在阅读时发生崩溃。",
    [118] = "阅读环境意外中断。",
    [119] = "触控连接中断。",
    [120] = "阅读环境可用空间不足，无法启动。",
    [126] = "阅读环境引导未完成。",
    [128] = "阅读服务未能就绪，请重试启动。",
    [129] = "微信读书响应超时，已返回 KOReader。",
}
local ctl = base .. "resident-v197/resident-ctl.sh"
local suspend_request = base .. "resident-v197-suspend-request"
function WeReadLab:suspendIfRequested()
    local owner = read(suspend_request)
    if not owner then return end
    os.remove(suspend_request)
    local state = read(base .. "resident-v197-state") or ""
    if owner:match("^%d+\n$") and state:match("^state=background\n") and state:match("\nowner=(%d+)\n") == owner:match("^(%d+)\n$")
        and controllerAlive() and not Device:getPowerDevice():isCharging() then
        logger.info("WeReadLab197 idle suspend")
        self.idle_suspend_session = state
        UIManager:suspend()
    end
end
local function residentState()
    if not read(ctl) then return "none" end
    local p = io.popen("/bin/sh " .. ctl .. " status 2>/dev/null")
    if not p then return "none" end
    local value = p:read("*l") or "none"
    p:close()
    return value
end
-- Before KOReader quits for any reason (exit, restart, USB mass storage,
-- power-off, reboot), stop a resident Android and wait for its full cleanup.
local function shutdownResident()
    local state = residentState()
    if state == "none" then return end
    local message = InfoMessage:new { text = "正在关闭后台 Android，请稍候…" }
    UIManager:show(message)
    pcall(function() UIManager:forceRePaint() end)
    local ok = os.execute("/bin/sh " .. ctl .. " shutdown 90 </dev/null >/dev/null 2>&1")
    logger.info("WeReadLab197 resident shutdown before quit", state, ok)
    UIManager:close(message)
end
if not PluginShare.kobo_resident_v197_quit_wrapped then
    PluginShare.kobo_resident_v197_quit_wrapped = true
    local original_quit = UIManager.quit
    UIManager.quit = function(...)
        local ok, err = pcall(shutdownResident)
        if not ok then logger.warn("WeReadLab197 resident shutdown failed", err) end
        return original_quit(...)
    end
end
-- Free space in the Android image, recorded by the session script when it
-- mounts and unmounts the image. Below 200 MB, warn (sessions stop by
-- themselves under 64 MB).
local function spaceWarning()
    local kb = tonumber((read(base .. "resident-v197/image-free-kb") or ""):match("^(%d+)"))
    if kb and kb < 204800 then
        return "注意：Android 镜像剩余空间只有 " .. math.floor(kb / 1024) .. " MB，低于 64 MB 时将无法启动，请及时清理或扩容。"
    end
end
-- Memory warning (2026-11-01): Android here runs with little memory to spare
-- (507 MB, no swap). Anything else holding RAM makes WeRead thrash: ~100 MB of
-- files left in /tmp (a tmpfs) turned 5 s book opens into a minute. Checked
-- when Android is started or brought back: /tmp use, KOReader's own memory,
-- and, before a fresh start, available memory (about 390 MB normally).
local function memoryWarning(fresh)
    local notes = {}
    local p = io.popen("df -k /tmp 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local used = tonumber(out:match("\n%S+%s+%d+%s+(%d+)"))
    if used and used > 20480 then
        notes[#notes + 1] = "设备的 /tmp 占用了 " .. math.floor(used / 1024) .. " MB 内存（/tmp 存在内存里），微信读书可能明显变慢；重启设备可清空。"
    end
    local rss = tonumber((read("/proc/self/status") or ""):match("VmRSS:%s+(%d+)"))
    if rss and rss > 81920 then
        notes[#notes + 1] = "KOReader 当前占用 " .. math.floor(rss / 1024) .. " MB 内存，微信读书可能变慢；可先关闭正在看的文档。"
    end
    if fresh then
        local avail = tonumber((read("/proc/meminfo") or ""):match("MemAvailable:%s+(%d+)"))
        if avail and avail < 337920 then
            notes[#notes + 1] = "当前可用内存只有 " .. math.floor(avail / 1024) .. " MB（通常约 390 MB），微信读书可能明显变慢。"
        end
    end
    if #notes > 0 then return "注意：" .. table.concat(notes, "\n") end
end
local function warnings(fresh)
    local space, memory = spaceWarning(), memoryWarning(fresh)
    if space and memory then return space .. "\n\n" .. memory end
    return space or memory
end
local function statusText()
    local value = read(base .. "v197-launch.state") or ""
    local current = stage()
    local text = messages[current] or "暂时无法读取运行状态。"
    if current == "starting" then
        local phase = value:match("\nphase=([%a_]+)\n")
        if phases[phase] then text = phases[phase] end
        local started = tonumber(value:match("\nstarted_uptime=([%d%.]+)\n"))
        local uptime = tonumber((read("/proc/uptime") or ""):match("^([%d%.]+)"))
        if started and uptime and started > 0 and uptime >= started then
            text = text .. "\n本轮已等待 " .. math.floor(uptime - started) .. " 秒。"
        end
    elseif current == "failed" then
        local code = tonumber(value:match("\nexit=(%d+)\n"))
        if code then text = (failures[code] or "启动或运行未完成。") .. "\n错误码：" .. code .. "。" end
    end
    local warn = warnings(false)
    if warn then text = text .. "\n\n" .. warn end
    return text
end
function WeReadLab:closeProgress()
    if self.progress_widget then
        self.progress_widget.dismiss_callback = nil
        UIManager:close(self.progress_widget)
        self.progress_widget = nil
    end
end
function WeReadLab:showStartupCard(phase)
    self:closeProgress()
    self.progress_phase = phase
    self.progress_widget = InfoMessage:new {
        text = "微信读书\n\n" .. (phases[phase] or "正在准备运行环境。")
            .. "\n\n首次登录后，请等待书架同步和书籍下载。",
        dismiss_callback = function() self.progress_widget = nil; self.show_progress = false end,
    }
    UIManager:show(self.progress_widget)
end
function WeReadLab:showStartupFailure()
    local ButtonDialog = require("ui/widget/buttondialog")
    local value = read(base .. "v197-launch.state") or ""
    local phase = value:match("\nphase=([%a_]+)\n")
    local code = tonumber(value:match("\nexit=(%d+)\n"))
    local summary = failures[code] or "微信读书启动未完成。"
    local dialog
    dialog = ButtonDialog:new {
        title = summary .. "\n" .. (phases[phase] or "正在准备运行环境。"),
        buttons = {
            {
                { text = "重试", callback = function()
                    if residentState() ~= "none" or controllerAlive()
                        or read(base .. "weread-launch.lock/owner") then
                        UIManager:show(InfoMessage:new { text = "正在清理上一次会话，请稍后重试。", timeout = 4 })
                        return
                    end
                    UIManager:close(dialog)
                    if self.startup_tuning then self:openTuning() else self:openResident() end
                end },
                { text = "返回 KOReader", callback = function() UIManager:close(dialog) end },
            },
            {
                { text = "查看错误码", callback = function()
                    UIManager:show(InfoMessage:new { text = "错误码 " .. tostring(code or "未知") })
                end },
            },
        },
    }
    UIManager:show(dialog)
end
function WeReadLab:updateProgress()
    if not self.show_progress then return end
    if stage() ~= "starting" then
        if controllerAlive() then self:closeProgress() end
        return
    end
    local phase = (read(base .. "v197-launch.state") or ""):match("\nphase=([%a_]+)\n")
    if self.progress_widget and self.progress_phase == phase then return end
    self:showStartupCard(phase)
end
-- Edge swipes in Android set the light behind KOReader's back, and KOReader
-- keeps its own copy of brightness and warmth: take the hardware values over
-- on return, so its menus show them and its next change starts from them.
local function readWhite()
    local fs = Device.frontlight_settings or {}
    return tonumber((read(fs.frontlight_white or "/sys/class/backlight/mxc_msp430.0/brightness") or ""):match("%d+"))
end
-- Hardware brightness when Android took the screen (rememberFrontlight), so
-- that a light nobody changed in Android leaves KOReader's state alone.
local white_at_launch
local function rememberFrontlight()
    white_at_launch = Device:hasFrontlight() and readWhite() or nil
end
local function syncFrontlight()
    if not Device:hasFrontlight() then return end
    local powerd = Device:getPowerDevice()
    local fs = Device.frontlight_settings or {}
    local white = readWhite()
    local before = powerd:frontlightIntensity()
    local launched_with = white_at_launch
    white_at_launch = nil
    -- Koboweread-Colour: a light that is merely off reads 0. Setting the
    -- intensity to 0 lost the remembered level, and KOReader then saved 0 (also
    -- into Nickel's FrontLightLevel), so turning the light on stayed dark.
    -- 0 now means "off" (level kept), and an unchanged light is left alone.
    if white and white ~= launched_with then
        if white == 0 then
            if powerd:isFrontlightOn() then powerd:turnOffFrontlight() end
        else
            if white ~= before then powerd:setIntensity(white) end
            if not powerd:isFrontlightOn() then powerd:turnOnFrontlight() end
        end
    end
    local mixer = Device:hasNaturalLight() and fs.frontlight_mixer and fs.nl_max
        and tonumber((read(fs.frontlight_mixer) or ""):match("%d+"))
    local warmth = powerd:frontlightWarmth()
    if mixer then
        local native = fs.nl_inverted and fs.nl_max - mixer or mixer
        -- KOReader's scale is finer (0-100): leave it alone when it maps to the same step.
        if powerd:toNativeWarmth(warmth) ~= native then powerd:setWarmth(powerd:fromNativeWarmth(native)) end
    end
    logger.info("WeReadLab197 frontlight synced", before, "->", powerd:frontlightIntensity(), warmth, "->", powerd:frontlightWarmth())
end
function WeReadLab:releaseAwake()
    if not self.keep_awake then return end
    UIManager:unschedule(self.monitor_task)
    self:closeProgress()
    self.show_progress = false
    -- Activity took place in the local Android window while KOReader was paused.
    -- Reset the original idle timer before restoring its normal policy.
    UIManager.event_hook:execute("InputEvent")
    local shared = self.awake_token
    shared.count = shared.count - 1
    if shared.count == 0 and PluginShare.kobo_weread_awake == shared then
        PluginShare.pause_auto_suspend = shared.previous
        PluginShare.kobo_weread_awake = nil
    end
    self.awake_token = nil
    UIManager:allowStandby()
    self.keep_awake = false
    if shared.count == 0 then logger.info("WeReadLab197 idle policy released") end
end
function WeReadLab:holdAwake(grace)
    if self.keep_awake then return end
    self.keep_awake = true
    self.launch_grace = grace or 0
    local shared = PluginShare.kobo_weread_awake
    if not shared then
        shared = { count = 0, previous = PluginShare.pause_auto_suspend }
        PluginShare.kobo_weread_awake = shared
        logger.info("WeReadLab197 idle policy acquired")
    end
    shared.count = shared.count + 1
    self.awake_token = shared
    PluginShare.pause_auto_suspend = true
    UIManager:preventStandby()
    self.monitor_task = function()
        -- Restart or odex compile from the launcher's 阅读优化 page
        -- (relaunch.sh, 2026-11-11): the session has ended and starts again
        -- by itself; say so and keep the Kobo awake until it does.
        local relaunch = (read(base .. "resident-v197/relaunch.state") or ""):match("^(%a+)")
        if relaunch then
            self.launch_grace = 0
            if self.relaunch_shown ~= relaunch then
                self:closeProgress()
                self.relaunch_shown = relaunch
                self.progress_widget = InfoMessage:new {
                    text = relaunch == "compiling" and "正在重新编译加速文件，通常约一两分钟，完成后自动打开微信读书。\n\n期间请不要关机。"
                        or "正在重启微信读书，设置随之生效，约 1 分钟后自动打开。",
                    dismiss_callback = function() self.progress_widget = nil end,
                }
                UIManager:show(self.progress_widget)
            end
            self.show_progress = true
            UIManager:scheduleIn(2, self.monitor_task)
            return
        end
        if self.relaunch_shown then
            self.relaunch_shown = nil
            self.launch_grace = 5
        end
        -- A resident Android in the background must not keep the Kobo awake.
        if controllerAlive() and stage() ~= "background" then
            self.launch_grace = 0
        elseif self.launch_grace > 0 then
            self.launch_grace = self.launch_grace - 1
        else
            local show_failure = self.show_progress and stage() == "failed"
            self:releaseAwake()
            if show_failure then self:showStartupFailure() end
            local ok, err = pcall(syncFrontlight)
            if not ok then logger.warn("WeReadLab197 frontlight sync failed", err) end
            self:suspendIfRequested()
            return
        end
        self:updateProgress()
        UIManager:scheduleIn(2, self.monitor_task)
    end
    UIManager:scheduleIn(2, self.monitor_task)
end
function WeReadLab:onResume()
    local session = self.idle_suspend_session
    self.idle_suspend_session = nil
    if not session then return end
    -- Let KOReader restore its screen and finish handling the wake event.
    UIManager:scheduleIn(1, function()
        if read(base .. "resident-v197-state") ~= session or not controllerAlive()
            or residentState() ~= "background" then return end
        if os.execute("/bin/sh " .. ctl .. " foreground </dev/null >/dev/null 2>&1") == 0 then
            self:holdAwake(15)
            logger.info("WeReadLab197 restoring foreground after idle suspend")
        end
    end)
end
-- Koboweread-Colour: "微信读书" on the Kobo home screen (NickelMenu, see
-- nickelmenu-weread) leaves a one-shot request and starts KOReader; open the
-- launcher once KOReader is up and online. A request older than two minutes
-- (KOReader did not get this far last time) is dropped.
local autostart_request = "/tmp/wereadkobo-autostart"
local function takeAutostart()
    local lfs = require("libs/libkoreader-lfs")
    local made = lfs.attributes(autostart_request, "modification")
    if not made then return false end
    os.remove(autostart_request)
    return os.time() - made <= 120
end
function WeReadLab:init()
    self.ui.menu:registerToMainMenu(self)
    if controllerAlive() and stage() ~= "background" then self:holdAwake(0) end
    if takeAutostart() then
        logger.info("WeReadLab197 autostart requested from the Kobo home screen")
        UIManager:scheduleIn(1, function()
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function() self:openResident() end)
        end)
    end
end
-- KOReader stays in memory, stopped, while Android runs (no swap, 507 MB).
-- Drop its rendered-page cache and collect garbage first, so the memory goes
-- to Android; the screen is restored from a framebuffer copy on return, and
-- pages are rendered again when needed. Off: resident-v197/koclear-disabled.
local function rssKB()
    local f = io.open("/proc/self/status", "r")
    if not f then return 0 end
    local s = f:read("*a"); f:close()
    return tonumber(s:match("VmRSS:%s*(%d+)")) or 0
end
local function freeReaderMemory()
    if read(base .. "resident-v197/koclear-disabled") then return end
    local before = rssKB()
    pcall(function() require("document/doccache"):clear() end)
    collectgarbage(); collectgarbage()
    logger.info("WeReadLab197 reader memory released", before, rssKB())
end
-- The other WeRead version's launcher (1.8.8 resident-v188/; 1.9.8 was removed 2026-11-11)
-- share the Android runtime: stop whichever is running first.
local others = { { "resident-v188/resident-ctl.sh", "1.8.8" } }
local function stopOther()
    for _, o in ipairs(others) do
        local other_ctl = base .. o[1]
        if read(other_ctl) then
            local p = io.popen("/bin/sh " .. other_ctl .. " status 2>/dev/null")
            local state = p and p:read("*l") or "none"
            if p then p:close() end
            if state ~= "none" then
                local message = InfoMessage:new { text = "正在关闭微信读书 " .. o[2] .. " 的后台 Android…" }
                UIManager:show(message)
                pcall(function() UIManager:forceRePaint() end)
                local ok = os.execute("/bin/sh " .. other_ctl .. " shutdown 90 </dev/null >/dev/null 2>&1")
                logger.info("WeReadLab197 other version stopped", other_ctl, state, ok)
                UIManager:close(message)
            end
        end
    end
end
-- "重新编译加速文件" (2026-11-10): WeRead's speed-profile odex is compiled on
-- the device from the methods ART recorded during reading. compile-menu.sh
-- runs fast-v197/compile-speed-profile.sh detached (about a minute, Android
-- closed) and logs to compile-menu.log; the menu polls that log, keeps the
-- Kobo awake meanwhile and shows the result.
local compile_log = base .. "resident-v197/compile-menu.log"
local function compileState()
    local log = read(compile_log)
    if not log then return "never" end
    local code = log:match("\nCOMPILE_MENU_DONE code=(%d+)")
    if code then return "done", tonumber(code), log end
    local boot = (read("/proc/sys/kernel/random/boot_id") or ""):match("^(%S+)")
    if boot and log:match("^COMPILE_MENU_BEGIN boot=(%S+)") == boot then return "running", nil, log end
    return "interrupted", nil, log
end
local function compileResult(code, log)
    if code == 0 and log:match("FAST_COMPILE_OUTPUT_BYTES=") then
        local bytes = tonumber(log:match("FAST_COMPILE_OUTPUT_BYTES=(%d+)")) or 0
        local seconds = tonumber(log:match("FAST_COMPILE_RESULT code=0 seconds=([%d%.]+)")) or 0
        return "加速文件已重新编译（" .. math.floor(bytes / 1048576) .. " MB，用时 " .. math.floor(seconds) .. " 秒）。下次启动微信读书生效。"
    elseif log:match("FAST_COMPILE_NO_PROFILE") then
        return "还没有阅读记录可用。请先正常阅读一段时间，再重新编译。"
    elseif log:match("COMPILE_REFUSED_IMAGE_UNCLEAN") then
        return "上次微信读书没有正常关闭。请先启动一次微信读书（启动时会自动检查并修复），正常关闭后台 Android，再重新编译。"
    elseif log:match("COMPILE_REFUSED_") then
        return "Android 还在运行，或上次没有清理完。请先“关闭后台 Android”，再重新编译。"
    elseif log:match("KERNEL_MODULES_MISSING") then
        return "当前固件没有对应的内核模块，无法编译。"
    elseif log:match("FAST_COMPILE_LOW_IMAGE_SPACE") then
        return "Android 镜像剩余空间不足，无法编译。"
    end
    return "编译没有完成（代码 " .. tostring(code) .. "）。原来的加速文件已保留，可稍后重试。"
end
function WeReadLab:watchCompile()
    if self.compile_task then return end
    UIManager:preventStandby()
    local previous = PluginShare.pause_auto_suspend
    PluginShare.pause_auto_suspend = true
    self.compile_task = function()
        local state, code, log = compileState()
        if state == "running" then
            UIManager:scheduleIn(3, self.compile_task)
            return
        end
        self.compile_task = nil
        PluginShare.pause_auto_suspend = previous
        UIManager:allowStandby()
        logger.info("WeReadLab197 compile finished", state, code)
        UIManager:show(InfoMessage:new { text = state == "done" and compileResult(code, log) or "编译被中断，原来的加速文件已保留。" })
    end
    UIManager:scheduleIn(3, self.compile_task)
end
function WeReadLab:compileOdex()
    if compileState() == "running" then
        self:watchCompile()
        UIManager:show(InfoMessage:new { text = "正在重新编译加速文件，通常约一两分钟，完成后会提示。", timeout = 5 })
        return
    end
    if residentState() ~= "none" or controllerAlive() then
        UIManager:show(InfoMessage:new { text = "请先“关闭后台 Android”，再重新编译。", timeout = 5 })
        return
    end
    if not read(base .. "resident-v197/compile-menu.sh") or not read(base .. "fast-v197/compile-speed-profile.sh") then
        UIManager:show(InfoMessage:new { text = "编译脚本尚未安装。", timeout = 5 })
        return
    end
    os.remove(compile_log)
    os.execute("/usr/bin/setsid " .. base .. "fd-clean-exec /bin/sh " .. base .. "resident-v197/compile-menu.sh </dev/null >/dev/null 2>&1 &")
    self:watchCompile()
    UIManager:show(InfoMessage:new { text = "已开始重新编译加速文件，通常约一两分钟，完成后会提示。\n\n期间请不要启动微信读书，也不要关机。", timeout = 8 })
end
function WeReadLab:openResident(tuning)
    -- A leftover from a 阅读优化 start that never got going.
    if not tuning then os.remove(base .. "resident-v197/tuning-once") end
    if compileState() == "running" then
        self:watchCompile()
        UIManager:show(InfoMessage:new { text = "正在重新编译加速文件，请等它完成后再启动。", timeout = 5 })
        return
    end
    stopOther()
    freeReaderMemory()
    rememberFrontlight()
    local state = residentState()
    if state == "background" then
        if os.execute("/bin/sh " .. ctl .. " foreground </dev/null >/dev/null 2>&1") == 0 then
            self:holdAwake(15)
            local warn = warnings(false)
            UIManager:show(InfoMessage:new { text = "正在切换到 Android…" .. (warn and ("\n\n" .. warn) or ""), timeout = warn and 6 or 3 })
        else
            UIManager:show(InfoMessage:new { text = "无法切换到后台 Android，请查看运行状态。", timeout = 5 })
        end
        return
    end
    if state ~= "none" or controllerAlive() then
        UIManager:show(InfoMessage:new { text = statusText(), timeout = 5 })
        return
    end
    if not read(base .. "resident-v197/launch-resident.sh") then
        UIManager:show(InfoMessage:new { text = "启动文件尚未安装。", timeout = 5 })
        return
    end
    self:holdAwake(5)
    self.show_progress = true
    self.startup_tuning = tuning
    os.execute("/usr/bin/setsid " .. base .. "fd-clean-exec /bin/sh " .. base .. "resident-v197/launch-resident.sh </dev/null >/dev/null 2>&1 &")
    self:showStartupCard("runtime_begin")
end
-- "阅读优化" (2026-11-11): the launcher's settings page. On a fresh start the
-- automatic WeRead start is skipped once (tuning-once, read by
-- resident-loop.sh): it would take the screen's input from the launcher.
-- With Android in the background the host brings the launcher's page up.
function WeReadLab:openTuning()
    if compileState() == "running" then
        self:watchCompile()
        UIManager:show(InfoMessage:new { text = "正在重新编译加速文件，请等它完成后再进入。", timeout = 5 })
        return
    end
    local state = residentState()
    if state == "background" then
        if os.execute("/bin/sh " .. ctl .. " tuning </dev/null >/dev/null 2>&1") == 0 then
            self:holdAwake(15)
            UIManager:show(InfoMessage:new { text = "正在切换到启动器的阅读优化页…", timeout = 3 })
        else
            UIManager:show(InfoMessage:new { text = "无法切换到后台 Android，请查看运行状态。", timeout = 5 })
        end
        return
    end
    if state ~= "none" or controllerAlive() then
        UIManager:show(InfoMessage:new { text = statusText(), timeout = 5 })
        return
    end
    local f = io.open(base .. "resident-v197/tuning-once", "w")
    if f then f:write("1\n"); f:close() end
    self:openResident(true)
end
function WeReadLab:stopResident()
    local state = residentState()
    if state == "none" then
        UIManager:show(InfoMessage:new { text = "后台没有常驻的 Android。", timeout = 4 })
        return
    end
    shutdownResident()
    UIManager:show(InfoMessage:new { text = residentState() == "none" and "后台 Android 已关闭。" or "已请求关闭，正在清理。", timeout = 4 })
end
function WeReadLab:onCloseWidget() self:releaseAwake() end
-- Kobo power-off/reboot run "poweroff -f"/"reboot" one second after these
-- events, without init unmounting anything: stop Android first.
function WeReadLab:onPowerOff() pcall(shutdownResident) end
function WeReadLab:onReboot() pcall(shutdownResident) end
function WeReadLab:setDisplayProfile(value)
    if value ~= "classic" and value ~= "reagl" and value ~= "reagl-text" then return end
    if controllerAlive() then
        UIManager:show(InfoMessage:new { text = "请在阅读结束后切换显示效果。", timeout = 5 })
        return
    end
    local f = io.open(base .. "resident-v197/display-profile", "w")
    if not f then
        UIManager:show(InfoMessage:new { text = "无法保存显示选项。", timeout = 5 })
        return
    end
    local ok = f:write(value .. "\n")
    local closed = f:close()
    UIManager:show(InfoMessage:new { text = ok and closed and "已保存，下次启动微信读书生效。" or "保存显示选项失败。", timeout = 5 })
end
local function displayProfile()
    local value = (read(base .. "resident-v197/display-profile") or "reagl-text"):match("^([^\r\n]+)")
    -- "fast4" (DU4) was removed: the panel did not show its updates. The
    -- launcher runs a leftover setting as the default.
    if value == "fast4" then return "reagl-text" end
    return value
end
function WeReadLab:addToMainMenu(items)
    items.weread_v197 = {
        text = "微信读书 1.9.7（启动器）",
        sorting_hint = "more_tools",
        sub_item_table = {
            { text = "Android 启动器（常驻，热启动）", callback = function() self:openResident() end },
            { text = "阅读优化（启动器设置页）", callback = function() self:openTuning() end },
            { text = "关闭后台 Android", callback = function() self:stopResident() end, separator = true },
            { text = "显示效果", sub_item_table = {
                { text = "标准（原显示方式）", checked_func = function() return displayProfile() == "classic" end, callback = function() self:setDisplayProfile("classic") end },
                { text = "REAGL（减少残影）", checked_func = function() return displayProfile() == "reagl" end, callback = function() self:setDisplayProfile("reagl") end },
                { text = "REAGL＋文字增强", checked_func = function() return displayProfile() == "reagl-text" end, callback = function() self:setDisplayProfile("reagl-text") end },
            } },
            { text = "重新编译加速文件（约一两分钟）", callback = function() self:compileOdex() end },
            { text = "操作说明", callback = function()
                UIManager:show(InfoMessage:new { text = "竖屏、按钮位于右侧：上键下一页，下键上一页，短按松手翻页；设备倒过来拿时画面、触摸和按键随之翻转。\n\n下一页键按住满 1 秒：立即全刷。上一页键按住满 3 秒后松手：PNG 截图保存到安装目录的 snapshot 文件夹。下一页键按住满 5 秒后松手：回到 Android 启动器。\n\n按键一侧的屏幕边缘上下滑动调亮度，另一侧调色温。\n\n同时按住两个翻页键满 2 秒后松开：返回 Android 启动器。\n\n长按左上角两秒后松手，或按电源键并松手：返回 KOReader，Android 保留在后台，可正常休眠，再次从菜单进入无需重新启动。\n\n退出、重启 KOReader、连接 USB 存储、关机前会自动关闭 Android。", timeout = 30 })
            end },
            {
                text = "查看运行状态",
                callback = function()
                    UIManager:show(InfoMessage:new { text = statusText(), timeout = 8 })
                end,
            },
        },
    }
end
return WeReadLab
