local CHECK_INTERVAL_SECONDS = 24 * 60 * 60
local RESULT_FILE_NAME = "aseprite-bin-updater-result.json"
local HELPER_TIMEOUT_TICKS = 1200

local updaterPlugin = nil
local buildInfo = nil
local installationDirectory = nil
local resultPath = nil
local pollTimer = nil
local startupTimer = nil
local activeDialog = nil

local function readJsonFile(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  local ok, value = pcall(json.decode, text)
  if ok then
    return value
  end
  return nil
end

local function quoteCommandArgument(value)
  return '"' .. tostring(value):gsub('"', '""') .. '"'
end

local function closeActiveDialog()
  if activeDialog then
    activeDialog:close()
    activeDialog = nil
  end
end

local function helperPath()
  return app.fs.joinPath(installationDirectory, "Invoke-AsepriteUpdate.ps1")
end

local function launchHelper(mode, stagingSource)
  os.remove(resultPath)
  local command = table.concat({
    'start "" /b powershell.exe',
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-WindowStyle Hidden",
    "-ExecutionPolicy Bypass",
    "-File", quoteCommandArgument(helperPath()),
    "-Mode", quoteCommandArgument(mode),
    "-InstallationDirectory", quoteCommandArgument(installationDirectory),
    "-ResultPath", quoteCommandArgument(resultPath),
    "-Repository", quoteCommandArgument(buildInfo.update.repository),
    stagingSource and ("-StagingSource " .. quoteCommandArgument(stagingSource)) or ""
  }, " ")
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function stopPolling()
  if pollTimer then
    pollTimer:stop()
    pollTimer = nil
  end
end

local function pollForResult(operation, onComplete)
  stopPolling()
  local pollTicks = 0
  local timeoutTicks = operation == "Check" and 120 or HELPER_TIMEOUT_TICKS
  pollTimer = Timer{
    interval = 0.5,
    ontick = function()
      pollTicks = pollTicks + 1
      if pollTicks >= timeoutTicks then
        stopPolling()
        onComplete{
          status = "error",
          message = "更新程序等待超时，请稍后重试。"
        }
        return
      end

      local result = readJsonFile(resultPath)
      if not result or result.operation ~= operation then
        return
      end
      if result.status == "checking" or
         result.status == "downloading" or
         result.status == "waiting-for-exit" then
        return
      end
      stopPolling()
      onComplete(result)
    end
  }
  pollTimer:start()
end

local function showError(message)
  closeActiveDialog()
  app.alert{
    title = "中文增强版更新",
    text = message or "更新操作失败，请稍后重试。",
    buttons = "确定"
  }
end

local function hasModifiedSprites()
  for _, sprite in ipairs(app.sprites) do
    if sprite.isModified then
      return true
    end
  end
  return false
end

local function startApply(stagingSource)
  if hasModifiedSprites() then
    app.alert{
      title = "请先保存文件",
      text = "还有未保存的画布。请先保存或关闭它们，再点击更新按钮。",
      buttons = "确定"
    }
    return
  end

  closeActiveDialog()
  if not launchHelper("Apply", stagingSource) then
    showError("无法启动更新程序，请检查 PowerShell 是否可用。")
    return
  end
  app.tip("Aseprite 即将退出，更新完成后会尝试自动重新启动。", 5)
  app.exit()
end

local function showReadyToInstall(result)
  closeActiveDialog()
  activeDialog = Dialog{
    title = "更新已下载",
    resizeable = false
  }
  activeDialog
    :label{
      text = "新版本已经下载并通过完整性校验。"
    }
    :label{
      text = "点击后将关闭 Aseprite、更新当前目录并尝试重新启动。"
    }
    :button{
      id = "restart",
      text = "立即重启并安装",
      onclick = function()
        startApply(result.stagingSource)
      end
    }
    :button{
      id = "later",
      text = "稍后",
      onclick = function()
        closeActiveDialog()
      end
    }
    :show{ wait = false }
end

local function startDownload()
  closeActiveDialog()
  activeDialog = Dialog{
    title = "正在下载更新",
    resizeable = false
  }
  activeDialog
    :label{
      text = "正在从你的 GitHub Actions 下载并校验最新产物…"
    }
    :label{
      text = "下载期间可以继续使用 Aseprite。"
    }
    :show{ wait = false }

  if not launchHelper("Download") then
    showError("无法启动下载程序，请检查 PowerShell 是否可用。")
    return
  end
  pollForResult("Download", function(result)
    if result.status == "downloaded" then
      showReadyToInstall(result)
    elseif result.status == "up-to-date" then
      closeActiveDialog()
      app.alert{
        title = "中文增强版更新",
        text = "下载前版本发生了变化；当前已经是最新版。",
        buttons = "确定"
      }
    elseif result.status == "auth-required" then
      showError(
        "下载 Actions 产物需要 GitHub 登录。\n\n" ..
        "请先在终端运行：gh auth login\n" ..
        "登录完成后再次点击“检查更新”。")
    else
      showError(result.message)
    end
  end)
end

local function showUpdateAvailable(result)
  closeActiveDialog()
  local manifest = result.manifest
  local compatibility = manifest.chineseMatchMode or "unknown"
  activeDialog = Dialog{
    title = "发现中文增强版更新",
    resizeable = false
  }
  activeDialog
    :label{
      text = "Aseprite " .. tostring(manifest.asepriteVersion) ..
             " · 汉化 " .. tostring(manifest.chineseRelease)
    }
    :label{
      text = "兼容状态：" .. compatibility
    }
    :button{
      id = "update",
      text = "下载并更新",
      onclick = startDownload
    }
    :button{
      id = "later",
      text = "稍后提醒",
      onclick = function()
        closeActiveDialog()
      end
    }
    :show{ wait = false }
end

local function startCheck(manual)
  if not buildInfo or not buildInfo.update or not buildInfo.update.repository then
    if manual then
      showError("当前便携版缺少自动更新配置。")
    end
    return
  end
  if not app.fs.isFile(helperPath()) then
    if manual then
      showError("当前便携版缺少 Invoke-AsepriteUpdate.ps1。")
    end
    return
  end

  if manual then
    app.tip("正在检查中文增强版更新…", 3)
  end
  if not launchHelper("Check") then
    if manual then
      showError("无法启动更新检查，请检查 PowerShell 是否可用。")
    end
    return
  end
  pollForResult("Check", function(result)
    if result.status == "update-available" then
      updaterPlugin.preferences.lastCheck = os.time()
      showUpdateAvailable(result)
    elseif result.status == "up-to-date" then
      updaterPlugin.preferences.lastCheck = os.time()
      if manual then
        app.alert{
          title = "中文增强版更新",
          text = "当前已经是最新版本。",
          buttons = "确定"
        }
      end
    elseif manual then
      showError(result.message)
    end
  end)
end

local function checkPreviousApplyResult()
  local result = readJsonFile(resultPath)
  if result and result.operation == "Apply" and result.status == "error" then
    showError("上一次自动更新没有完成：\n" .. tostring(result.message))
  end
end

function init(plugin)
  updaterPlugin = plugin
  installationDirectory = app.fs.filePath(app.fs.appPath)
  resultPath = app.fs.joinPath(app.fs.tempPath, RESULT_FILE_NAME)
  buildInfo = readJsonFile(app.fs.joinPath(installationDirectory, "build-info.json"))

  plugin:newCommand{
    id = "AsepriteBinCheckUpdates",
    title = "检查中文增强版更新…",
    group = "help_about",
    onclick = function()
      startCheck(true)
    end
  }

  checkPreviousApplyResult()

  local lastCheck = tonumber(plugin.preferences.lastCheck or 0) or 0
  if os.time() - lastCheck >= CHECK_INTERVAL_SECONDS then
    startupTimer = Timer{
      interval = 1.5,
      ontick = function()
        startupTimer:stop()
        startupTimer = nil
        startCheck(false)
      end
    }
    startupTimer:start()
  end
end

function exit(plugin)
  stopPolling()
  if startupTimer then
    startupTimer:stop()
    startupTimer = nil
  end
  closeActiveDialog()
end
