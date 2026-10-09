@echo off
chcp 936 >nul
title 全局代理开关
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0proxy.ps1" -Action menu
exit /b 0
