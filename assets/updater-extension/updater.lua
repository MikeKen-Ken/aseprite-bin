local CHECK_INTERVAL_SECONDS = 24 * 60 * 60
local RESULT_FILE_PREFIX = "aseprite-bin-updater-result-"
local CANCEL_FILE_PREFIX = "aseprite-bin-updater-cancel-"
local APPLY_RESULT_FILE_PREFIX = "aseprite-bin-updater-apply-"
local SESSION_ID = tostring({}):gsub("[^0-9A-Za-z]", "")
local HELPER_TIMEOUT_TICKS = 1200
local CHECK_TIMEOUT_TICKS = 120

local updaterPlugin = nil
local buildInfo = nil
local installationDirectory = nil
local installationKey = nil
local applyResultPath = nil
local activeResultPath = nil
local activeCancellationPath = nil
local pollTimer = nil
local startupTimer = nil
local activeDialog = nil
local activeOperation = nil
local activeRequestId = nil
local pollCancelled = false
local closingDialogInternally = false
local downloadProgressPercent = 0
local downloadProgressKnown = false

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
    local dialog = activeDialog
    activeDialog = nil
    closingDialogInternally = true
    dialog:close()
    closingDialogInternally = false
  end
end

local function helperPath()
  return app.fs.joinPath(installationDirectory, "Invoke-AsepriteUpdate.ps1")
end

local function loginHelperPath()
  return app.fs.joinPath(installationDirectory, "login-github.cmd")
end

local function pathKey(value)
  local hash = 0
  local normalized = tostring(value):lower()
  for index = 1, #normalized do
    hash = (hash * 131 + normalized:byte(index)) % 2147483647
  end
  return tostring(hash)
end

local function newRequestId()
  return string.format(
    "%s-%s-%d-%d-%d",
    installationKey,
    SESSION_ID,
    os.time(),
    math.floor((os.clock() % 1) * 1000000),
    math.random(100000, 999999))
end

local function clearActiveOperation(removeFiles)
  local resultToRemove = activeResultPath
  local cancellationToRemove = activeCancellationPath
  activeOperation = nil
  activeRequestId = nil
  activeResultPath = nil
  activeCancellationPath = nil
  pollCancelled = false
  if removeFiles then
    if resultToRemove then
      os.remove(resultToRemove)
    end
    if cancellationToRemove then
      os.remove(cancellationToRemove)
    end
  end
end

local function stopPolling()
  if pollTimer then
    pollTimer:stop()
    pollTimer = nil
  end
end

local function signalCancellation()
  if not activeCancellationPath then
    return
  end
  local file = io.open(activeCancellationPath, "wb")
  if file then
    file:write("cancel")
    file:close()
  end
end

local function cancelActiveOperation(dialogAlreadyClosed)
  if not activeOperation then
    return
  end
  signalCancellation()
  pollCancelled = true
  stopPolling()
  clearActiveOperation(false)
  if not dialogAlreadyClosed then
    closeActiveDialog()
  end
  app.tip("已取消更新操作。后台下载正在停止并清理临时文件。", 4)
end

local function formatBytes(value)
  local bytes = tonumber(value or 0) or 0
  if bytes >= 1024 * 1024 then
    return string.format("%.1f MB", bytes / (1024 * 1024))
  elseif bytes >= 1024 then
    return string.format("%.1f KB", bytes / 1024)
  end
  return string.format("%d B", math.floor(bytes))
end

local function updateStatusLabel(result)
  local status = result and result.status
  if not activeDialog or not status then
    return
  end
  local text = STATUS_LABELS[status]
  if status == "downloading" and result.progressPercent then
    downloadProgressPercent = math.max(
      0,
      math.min(100, tonumber(result.progressPercent) or 0))
    downloadProgressKnown = true
    text = string.format(
      "正在下载构建产物… %d%%（%s / %s）",
      math.floor(downloadProgressPercent),
      formatBytes(result.bytesDownloaded),
      formatBytes(result.totalBytes))
    pcall(function()
      activeDialog:repaint()
    end)
  end
  if text then
    pcall(function()
      activeDialog:modify{ id = "status", text = text }
    end)
  end
end

-- Launch PowerShell detached via cmd's start builtin so os.execute returns
-- immediately and does not freeze the Aseprite UI during network I/O.
local function launchHelper(mode, stagingSource)
  activeRequestId = newRequestId()
  if mode == "Apply" then
    activeResultPath = applyResultPath
    activeCancellationPath = nil
  else
    activeResultPath = app.fs.joinPath(
      app.fs.tempPath,
      RESULT_FILE_PREFIX .. activeRequestId .. ".json")
    activeCancellationPath = app.fs.joinPath(
      app.fs.tempPath,
      CANCEL_FILE_PREFIX .. activeRequestId .. ".flag")
  end
  os.remove(activeResultPath)
  if activeCancellationPath then
    os.remove(activeCancellationPath)
  end
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
    "-ResultPath", quoteCommandArgument(activeResultPath),
    "-Repository", quoteCommandArgument(buildInfo.update.repository),
    "-RequestId", quoteCommandArgument(activeRequestId),
    activeCancellationPath and
      ("-CancellationPath " .. quoteCommandArgument(activeCancellationPath)) or "",
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
        signalCancellation()
        clearActiveOperation(false)
        onComplete{
          status = "error",
          message = "更新程序等待超时，请稍后重试。"
        }
        return
      end

      local result = readJsonFile(activeResultPath)
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
        updateStatusLabel(result)
        return
      end

      stopPolling()
      clearActiveOperation(true)
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

local function launchGitHubLogin()
  local path = loginHelperPath()
  if not app.fs.isFile(path) then
    return false
  end
  local command =
    'cmd.exe /c start "" ' .. quoteCommandArgument(path)
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function showGitHubLogin(onRetry)
  closeActiveDialog()
  if not launchGitHubLogin() then
    showError(
      "无法打开 GitHub 登录窗口。\n\n" ..
      "请确认当前便携版包含 login-github.cmd。")
    return
  end
  app.tip("GitHub 登录窗口已自动打开，请在浏览器中完成验证。", 5)
  activeDialog = Dialog{
    title = "需要登录 GitHub",
    resizeable = false
  }
  activeDialog
    :label{
      text = "下载 Actions 构建产物需要 GitHub 身份验证。"
    }
    :label{
      text = "登录窗口和浏览器已经自动打开，请按页面提示完成验证。"
    }
    :button{
      id = "retry",
      text = "登录完成，继续下载",
      onclick = function()
        closeActiveDialog()
        onRetry()
      end
    }
    :button{
      id = "cancel",
      text = "取消",
      onclick = function()
        closeActiveDialog()
      end
    }
    :show{ wait = false }
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

local function showProgressDialog(title, statusText, hintText, showProgress)
  closeActiveDialog()
  downloadProgressPercent = 0
  downloadProgressKnown = false
  activeDialog = Dialog{
    title = title,
    resizeable = false,
    onclose = function()
      if closingDialogInternally then
        return
      end
      activeDialog = nil
      cancelActiveOperation(true)
    end
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
  if showProgress then
    activeDialog:canvas{
      id = "progress",
      width = 260,
      height = 12,
      autoscaling = true,
      onpaint = function(event)
        local context = event.context
        context.color = Color{ r = 86, g = 86, b = 86, a = 255 }
        context:fillRect(Rectangle(0, 0, context.width, context.height))
        if downloadProgressKnown then
          local width = math.floor(
            context.width * downloadProgressPercent / 100)
          if width > 0 then
            context.color = Color{ r = 45, g = 156, b = 219, a = 255 }
            context:fillRect(Rectangle(0, 0, width, context.height))
          end
        end
      end
    }
  end
  activeDialog
    :button{
      id = "cancel",
      text = "取消",
      onclick = function()
        cancelActiveOperation(false)
      end
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
    clearActiveOperation(true)
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
    "下载期间可以继续使用 Aseprite。",
    true)

  activeOperation = "Download"
  if not launchHelper("Download") then
    clearActiveOperation(true)
    showError("无法启动下载程序，请检查 PowerShell 是否可用。")
    return
  end
  updateStatusLabel{ status = "checking" }
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
      showGitHubLogin(startDownload)
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
      "检查期间可以继续使用 Aseprite。",
      false)
  end

  activeOperation = "Check"
  if not launchHelper("Check") then
    clearActiveOperation(true)
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
  local result = readJsonFile(applyResultPath)
  if result and result.operation == "Apply" and result.status == "error" then
    showError("上一次自动更新没有完成：\n" .. tostring(result.message))
  end
  if result then
    os.remove(applyResultPath)
  end
end

function init(plugin)
  updaterPlugin = plugin
  math.randomseed(os.time())
  installationDirectory = app.fs.filePath(app.fs.appPath)
  installationKey = pathKey(installationDirectory)
  applyResultPath = app.fs.joinPath(
    app.fs.tempPath,
    APPLY_RESULT_FILE_PREFIX .. installationKey .. ".json")
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
  if activeOperation and activeOperation ~= "Apply" then
    signalCancellation()
  end
  clearActiveOperation(false)
  if startupTimer then
    startupTimer:stop()
    startupTimer = nil
  end
  closeActiveDialog()
end
