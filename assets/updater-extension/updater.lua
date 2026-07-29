local CHECK_INTERVAL_SECONDS = 24 * 60 * 60
local RESULT_FILE_NAME = "aseprite-bin-updater-result.json"
local HELPER_TIMEOUT_TICKS = 1200
local CHECK_TIMEOUT_TICKS = 120

local updaterPlugin = nil
local buildInfo = nil
local installationDirectory = nil
local resultPath = nil
local pollTimer = nil
local startupTimer = nil
local activeDialog = nil
local activeOperation = nil
local activeRequestId = nil
local pollCancelled = false

local STATUS_LABELS = {
  starting = "正在启动更新程序…",
  checking = "正在检查更新清单…",
  authenticating = "正在验证 GitHub 登录…",
  downloading = "正在下载构建产物…",
  verifying = "正在校验并解压产物…",
  extracting = "正在解压产物…",
  ["waiting-for-exit"] = "等待 Aseprite 退出以完成安装…"
}

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

local function newRequestId()
  return string.format("%d-%d", os.time(), math.random(100000, 999999))
end

local function clearActiveOperation()
  activeOperation = nil
  activeRequestId = nil
  pollCancelled = false
end

local function stopPolling()
  if pollTimer then
    pollTimer:stop()
    pollTimer = nil
  end
end

local function cancelActiveOperation()
  if not activeOperation then
    return
  end
  pollCancelled = true
  stopPolling()
  clearActiveOperation()
  closeActiveDialog()
  app.tip("已取消更新操作。后台任务如仍在运行，结果将被忽略。", 4)
end

local function updateStatusLabel(status)
  if not activeDialog or not status then
    return
  end
  local text = STATUS_LABELS[status]
  if text then
    pcall(function()
      activeDialog:modify{ id = "status", text = text }
    end)
  end
end

-- Launch PowerShell detached via cmd's start builtin so os.execute returns
-- immediately and does not freeze the Aseprite UI during network I/O.
local function launchHelper(mode, stagingSource)
  os.remove(resultPath)
  activeRequestId = newRequestId()
  local command = table.concat({
    'cmd.exe /c start "" /b powershell.exe',
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
    "-RequestId", quoteCommandArgument(activeRequestId),
    stagingSource and ("-StagingSource " .. quoteCommandArgument(stagingSource)) or ""
  }, " ")
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function pollForResult(operation, onComplete)
  stopPolling()
  pollCancelled = false
  local pollTicks = 0
  local timeoutTicks = operation == "Check" and CHECK_TIMEOUT_TICKS or HELPER_TIMEOUT_TICKS
  local requestId = activeRequestId
  pollTimer = Timer{
    interval = 0.5,
    ontick = function()
      if pollCancelled or requestId ~= activeRequestId then
        stopPolling()
        return
      end

      pollTicks = pollTicks + 1
      if pollTicks >= timeoutTicks then
        stopPolling()
        clearActiveOperation()
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
      if result.requestId and result.requestId ~= requestId then
        return
      end

      if result.status == "starting" or
         result.status == "checking" or
         result.status == "authenticating" or
         result.status == "downloading" or
         result.status == "verifying" or
         result.status == "extracting" or
         result.status == "waiting-for-exit" then
        updateStatusLabel(result.status)
        return
      end

      stopPolling()
      clearActiveOperation()
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

local function showBusyAlert()
  app.alert{
    title = "中文增强版更新",
    text = "正在检查或下载更新，请稍候再试。",
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

local function showProgressDialog(title, statusText, hintText)
  closeActiveDialog()
  activeDialog = Dialog{
    title = title,
    resizeable = false
  }
  activeDialog
    :label{
      id = "status",
      text = statusText
    }
    :label{
      id = "hint",
      text = hintText
    }
    :button{
      id = "cancel",
      text = "取消",
      onclick = cancelActiveOperation
    }
    :show{ wait = false }
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
  activeOperation = "Apply"
  if not launchHelper("Apply", stagingSource) then
    clearActiveOperation()
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
  if activeOperation then
    showBusyAlert()
    return
  end

  showProgressDialog(
    "正在下载更新",
    STATUS_LABELS.starting,
    "下载期间可以继续使用 Aseprite。")

  activeOperation = "Download"
  if not launchHelper("Download") then
    clearActiveOperation()
    showError("无法启动下载程序，请检查 PowerShell 是否可用。")
    return
  end
  updateStatusLabel("checking")
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
  if activeOperation then
    if manual then
      showBusyAlert()
    end
    return
  end

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
    showProgressDialog(
      "正在检查更新",
      STATUS_LABELS.checking,
      "检查期间可以继续使用 Aseprite。")
  end

  activeOperation = "Check"
  if not launchHelper("Check") then
    clearActiveOperation()
    if manual then
      showError("无法启动更新检查，请检查 PowerShell 是否可用。")
    else
      closeActiveDialog()
    end
    return
  end

  pollForResult("Check", function(result)
    if result.status == "update-available" then
      updaterPlugin.preferences.lastCheck = os.time()
      showUpdateAvailable(result)
    elseif result.status == "up-to-date" then
      updaterPlugin.preferences.lastCheck = os.time()
      closeActiveDialog()
      if manual then
        app.alert{
          title = "中文增强版更新",
          text = "当前已经是最新版本。",
          buttons = "确定"
        }
      end
    else
      if manual then
        showError(result.message)
      else
        closeActiveDialog()
      end
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
  math.randomseed(os.time())
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
  clearActiveOperation()
  if startupTimer then
    startupTimer:stop()
    startupTimer = nil
  end
  closeActiveDialog()
end
