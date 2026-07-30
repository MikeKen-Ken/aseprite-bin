@echo off
setlocal
chcp 65001 >nul
title Aseprite 中文增强版 - 登录 GitHub

echo.
echo ============================================================
echo   Aseprite 中文增强版 - GitHub 登录
echo ============================================================
echo.

where gh.exe >nul 2>&1
if errorlevel 1 (
  echo 未找到 GitHub CLI。
  echo.
  echo 请先安装：https://cli.github.com/
  echo 安装完成后，再从 Aseprite 点击“登录 GitHub”。
  echo.
  pause
  exit /b 1
)

echo 即将打开浏览器进行 GitHub 身份验证。
echo 如果浏览器没有自动打开，请按照窗口中的网址和验证码操作。
echo.

gh.exe auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow"
if errorlevel 1 (
  echo.
  echo 登录没有完成，请检查上方提示后重试。
  echo.
  pause
  exit /b 1
)

echo.
echo 登录成功。
echo 现在可以关闭此窗口，返回 Aseprite 点击“登录完成，继续下载”。
echo.
pause
exit /b 0
