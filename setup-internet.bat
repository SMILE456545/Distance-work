@echo off
chcp 65001 >nul
title RemoteDesk - setup
cd /d "%~dp0"
python server\setup_internet.py
