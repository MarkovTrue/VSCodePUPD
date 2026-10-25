#include-once

#include "..\..\AutoitFluentSkin\Include\FluentCore.au3"

; ============================================================================
;  Common.au3
;  Общее для всех модулей: имя, пути рядом с программой, цвета, типографика,
;  метрика окон и состояние обновления - что обновляем, куда и что скачано.
; ============================================================================

; Версия exe, менять здесь вместе с $gc_sAppVer. Aut2Exe берёт pragma и из подключаемого файла
#pragma compile(ProductVersion, 1.04)
#pragma compile(FileVersion, 1.04)

Global Const $gc_sAppName = "VSCodePUPD"
Global Const $gc_sAppVer = "1.04"
Global Const $gc_sTitle = $gc_sAppName & " " & $gc_sAppVer

; Тот же endpoint, что updateUrl в product.json сборки. Лежит здесь: его показывает и окно проверки
Global Const $gc_sUpdateApi = "https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest"

Global Const $gc_sIniFile = @ScriptDir & "\VSCodePUPD.ini"
Global Const $gc_sLogFile = @ScriptDir & "\VSCodePUPD.log"

; Разблокировка папки. Рядом с exe нужен драйвер USRFindHandle64.sys: без него LockHunter
; отвечает 'разблокировал', а папку не отдаёт. CRDllUnload64.dll выгружает чужие DLL из папки.
Global Const $gc_sLockHunter = @ScriptDir & "\Apps\LockHunter64.exe"

; ============================================================
; Типографика и метрика
; ============================================================

; Шкала и высота контрола – стандарты AutoitFluentSkin. Окна-диалоги с короткими фразами,
; поэтому основной текст BodyLarge (14 px), версии – Subtitle (20 px), подстрочник – Caption (12 px)
Global Const $gc_nFontBody = $gc_nFluentBodyLarge, $gc_nFontTitle = $gc_nFluentSubtitle
Global Const $gc_nFontCaption = $gc_nFluentCaption

Global Const $gc_iPad = 20, $gc_iBtnGap = 8
Global Const $gc_iBtnMinWidth = 96, $gc_iBtnPadX = 16, $gc_iBtnHeight = $gc_iFluentCtrlH

; Ширина первого окна: оно не пересоздаётся между состояниями, растёт только в высоту
Global Const $gc_iPopupWidth = 385

; Разделитель частей подстрочника: 'имя  •  размер  •  скорость'
Global Const $gc_sDot = "  " & ChrW(0x2022) & "  "

; ============================================================
; Цвета тёмной темы
; ============================================================
; Фон, кнопки, поле ввода, текст и статусы - палитра Fluent: $g_iFluentText1, подстрочник
; $g_iFluentText3, готово / внимание / ошибка - $g_iFluentOk, Warn, Err. Здесь - только свои
; цвета полос. Полоса прогресса - акцентом Fluent, как главная кнопка под ней

Global Const $gc_iClrThumb = 0x6A6A6A ; бегунок прокрутки таблицы держателей
Global Const $gc_iClrBarBg = 0x333333
Global Const $gc_iClrBar = 0x0F6CBD
Global Const $gc_iClrBarErr = 0xE81123
Global Const $gc_iClrRun = 0x4CC2FF
Global Const $gc_iClrWait = 0x6F6F6F

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
