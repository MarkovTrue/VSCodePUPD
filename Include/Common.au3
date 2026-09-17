#include-once

; ============================================================================
;  Common.au3
;  Общее для всех модулей: имя, пути рядом с программой, цвета, типографика,
;  метрика окон и состояние обновления - что обновляем, куда и что скачано.
; ============================================================================

Global Const $gc_sAppName = "VSCodePUPD"
Global Const $gc_sAppVer = "1.03"
Global Const $gc_sTitle = $gc_sAppName & " " & $gc_sAppVer

; Тот же endpoint, что updateUrl в product.json сборки. Лежит здесь: его показывает и окно проверки
Global Const $gc_sUpdateApi = "https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest"

Global Const $gc_sIniFile = @ScriptDir & "\VSCodePUPD.ini"
Global Const $gc_sLogFile = @ScriptDir & "\VSCodePUPD.log"

; ============================================================
; Типографика и метрика
; ============================================================

; Fluent 2 в пунктах (1 pt = 1,333 px при 96 DPI): Subtitle 20 px, Body 14 px, Caption 12 px.
; Мельче 9 pt руководство по Win32 не разрешает.
Global Const $gc_nFontBody = 10.5, $gc_nFontTitle = 15, $gc_nFontCaption = 9

Global Const $gc_iPad = 20, $gc_iBtnGap = 8
Global Const $gc_iBtnMinWidth = 96, $gc_iBtnPadX = 16, $gc_iBtnHeight = 26

; Ширина первого окна: оно не пересоздаётся между состояниями, растёт только в высоту
Global Const $gc_iPopupWidth = 385

; Разделитель частей подстрочника: 'имя  •  размер  •  скорость'
Global Const $gc_sDot = "  " & ChrW(0x2022) & "  "

; ============================================================
; Цвета тёмной темы
; ============================================================

Global Const $gc_iClrBg = 0x1F1F1F
Global Const $gc_iClrText = 0xE6E6E6
Global Const $gc_iClrDim = 0x9A9A9A
Global Const $gc_iClrAccent = 0x0078D4
Global Const $gc_iClrAccentHot = 0x1A88E0
Global Const $gc_iClrBtn = 0x3A3A3A
Global Const $gc_iClrBtnHot = 0x4A4A4A
Global Const $gc_iClrBtnDis = 0x2A2A2A
Global Const $gc_iClrBtnDisText = 0x6A6A6A
Global Const $gc_iClrBarBg = 0x333333
Global Const $gc_iClrBar = 0x0A84FF
Global Const $gc_iClrBarErr = 0xE81123
Global Const $gc_iClrOk = 0x6CCB5F
Global Const $gc_iClrRun = 0x4CC2FF
Global Const $gc_iClrErr = 0xFF8A8A
Global Const $gc_iClrWait = 0x6F6F6F
Global Const $gc_iClrWarn = 0xFFCC66

; DWMWA_USE_IMMERSIVE_DARK_MODE: атрибут переименован между сборками Windows
Global Const $gc_iDwmDarkMode = (@OSBuild <= 18985) ? 19 : 20

; ============================================================
; Состояние обновления
; ============================================================

; Настройки, читаются из ini рядом с программой
Global $g_sTargetPath = "", $g_sCodeExe = "", $g_sWorkDir = ""
Global $g_sDataPath = ""
Global $g_bDataInside = True ; папку данных надо уносить только если она внутри VS Code

; Что предлагает сервер и что уже скачано
Global $g_sVerCur = "", $g_sVerNew = "", $g_sUrl = "", $g_sHash = "", $g_sZipFile = ""
Global $g_iVerStamp = 0 ; дата выпуска обновления, unix-время в миллисекундах
Global $g_iZipSize = 0

; Аргументы, которые уйдут в Code.exe, и режим без окон
Global $g_sPassArgs = "", $g_bSilent = False
