@echo off
chcp 936 >nul
title Hermes 安装加速器
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hermes-vpn.ps1" -Action menu
exit /b 0
