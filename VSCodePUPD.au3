#pragma compile(Out, #Build\VSCodePUPD.exe)
#pragma compile(Icon, Assets\Icon.ico)
#pragma compile(ProductName, VSCodePUPD)
#pragma compile(FileDescription, Launcher and updater for portable VS Code)
#pragma compile(FileVersion, 1.01.0.0)

#NoTrayIcon

#include <AutoItConstants.au3>
#include <Date.au3>
#include <FileConstants.au3>
#include <GUIConstantsEx.au3>
#include <InetConstants.au3>
#include <MsgBoxConstants.au3>
#include <SendMessage.au3>
#include <StaticConstants.au3>
#include <WinAPI.au3>
#include <WinAPIFiles.au3>
#include <WinAPIGdi.au3>
#include <WindowsConstants.au3>

#include "Include/Archive.au3"
#include "Include/Downloader.au3"
#include "Include/Util.au3"

Opt("GUIOnEventMode", 1)
Opt("MustDeclareVars", 1)

; ============================================================
; Константы
; ============================================================

Global Const $gc_sAppName = "VSCodePUPD"
Global Const $gc_sAppVer = "1.01"
Global Const $gc_sTitle = $gc_sAppName & " " & $gc_sAppVer

Global Const $gc_sIniFile = @ScriptDir & "\VSCodePUPD.ini"
Global Const $gc_sLogFile = @ScriptDir & "\VSCodePUPD.log"
; Строки окна настройки: участвуют в расчёте ширины окна, поэтому нужны заранее
Global Const $gc_sDataPrefix = "Папка пользователя: "

; Запас поверх размера архива: распакованная сборка примерно вдвое больше,
; и обе версии какое-то время лежат на диске одновременно
Global Const $gc_nSpaceFactor = 3.5

; Тот же endpoint, что указан в product.json сборки как updateUrl
Global Const $gc_sUpdateApi = "https://update.code.visualstudio.com/api/update/win32-x64-archive/stable/latest"
Global Const $gc_iCheckTimeout = 4000 ; мс: дольше ждать нельзя, лаунчер стоит перед запуском редактора

; Единая метрика окон: поле по краям, кнопки одного размера и с одинаковым зазором
Global Const $gc_iPad = 20, $gc_iBtnGap = 8
Global Const $gc_iBtnMinWidth = 96, $gc_iBtnPadX = 16, $gc_iBtnHeight = 26

Global Const $gc_iSplashWidth = 340, $gc_iSplashHeight = 120
Global Const $gc_iSplashActionTop = 72 ; общая зона: полоса при проверке, кнопки при вопросе

; Типографика Fluent 2 в пунктах (при 96 DPI 1 pt = 1,333 px):
; Subtitle 20 px - заголовок, Body 14 px - основной текст,
; Caption 12 px - серый вторичный. Мельче 9 pt руководство по Win32 не разрешает.
Global Const $gc_nFontBody = 10.5, $gc_nFontTitle = 15, $gc_nFontCaption = 9

; Геометрия основного окна: шаги начинаются с $gc_iStepTop и идут с шагом $gc_iStepPitch
Global Const $gc_iMainWidth = 600
Global Const $gc_iStepTop = 82, $gc_iStepPitch = 24
Global Const $gc_iBarLeft = $gc_iPad, $gc_iBarWidth = $gc_iMainWidth - 2 * $gc_iPad, $gc_iBarHeight = 6
Global Const $gc_iBtnRight = $gc_iMainWidth - $gc_iPad
Global Const $gc_iStepInfoLeft = 300 ; колонка с подробностями шага, выравнивание по правому краю

; Цвета тёмной темы
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

Global Const $gc_sMarkWait = ChrW(0x25CB) ; ○
Global Const $gc_sMarkRun = ChrW(0x25CF)  ; ●
Global Const $gc_sMarkDone = ChrW(0x2713) ; ✓
Global Const $gc_sMarkErr = ChrW(0x2715)  ; ✕

; Список шагов зависит от того, лежит ли папка данных внутри VS Code,
; поэтому собирается в _BuildSteps. Сверка SHA-256 своего пункта не имеет:
; она часть шага загрузки.
Global $g_aStepTitle[1] = [""], $g_aStepWeight[1] = [100]
Global $g_iStepDownload = 1, $g_iStepBackup = -1, $g_iStepRemove = 2
Global $g_iStepUnpack = 3, $g_iStepRestore = -1, $g_iStepLaunch = 4

; Полный список шагов: [ключ, заголовок, вес, нужен только при данных внутри].
; Индексы шагов выводятся из него, поэтому при правке списка ничего
; больше подкручивать не надо.
Global Const $gc_aStepPlan[7][4] = [ _
		["check", "Проверка обновления", 3, False], _
		["download", "Загрузка архива", 46, False], _
		["backup", "Резервная копия папки пользователя", 3, True], _
		["remove", "Удаление старой версии в корзину", 10, False], _
		["unpack", "Распаковка архива", 30, False], _
		["restore", "Восстановление папки пользователя", 6, True], _
		["launch", "Запуск VS Code", 2, False]]

; ============================================================
; Глобальные переменные
; ============================================================

; GUI: маленькое окно проверки
Global $g_hSplash = 0, $g_iSplashText, $g_iSplashSub, $g_iSplashBarBg, $g_iSplashBar
Global $g_iSplashBtnUpdate = 0, $g_iSplashBtnRun = 0

; GUI: окно первого запуска
Global $g_hSetup = 0, $g_iSetupInput, $g_iSetupData
Global $g_iSetupBrowse = 0, $g_iSetupSave = 0, $g_iSetupCancel = 0

; GUI: основное окно
Global $g_hMain = 0, $g_iHero, $g_iHeroArrow, $g_iHeroNew, $g_iHeroSub, $g_iBarBg, $g_iBar
Global $g_iStatus, $g_iStatusInfo
Global $g_iBtnMain = 0, $g_iBtnAlt = 0
Global $g_iBarTop = 0, $g_iButtonTop = 0 ; считаются от числа шагов при построении окна
Global $g_aMarker[1], $g_aStepLabel[1], $g_aStepSub[1]

; Кнопки-Label под подсветку наведения: [[ControlID, базовый цвет, цвет наведения, доступна]]
Global $g_aHotBtn[0][4]

; Настройки, читаются из ini рядом с программой
Global $g_sTargetPath = "", $g_sCodeExe = "", $g_sWorkDir = ""
Global $g_sDataPath = ""
Global $g_bDataInside = True ; папку данных надо уносить только если она внутри VS Code

; Состояние
Global $g_sVerCur = "", $g_sVerNew = "", $g_sUrl = "", $g_sHash = "", $g_sZipFile = ""
Global $g_iVerStamp = 0 ; дата выпуска обновления, unix-время в миллисекундах
Global $g_iZipSize = 0
Global $g_iChoice = 0 ; 0 - ждём решения, 1 - обновить, 2 - запустить без обновления
Global $g_bCancel = False, $g_bCancelLocked = False
Global $g_sPassArgs = "", $g_bSilent = False

; Итоги завершённых шагов: показываются подстрочником рядом с пунктом
Global $g_sDownloadSummary = "", $g_sUnpackSummary = ""

; ============================================================
; Стартовая последовательность
; ============================================================

_ParseCmdLine()
_Util_LogStart($gc_sLogFile, $gc_sTitle & " запуск" & ($g_bSilent ? " (/silent)" : ""))
_LoadConfig() ; внутри же разбирается с последствиями прерванного прогона
_BuildSteps()

$g_sVerCur = _GetVSCodeVers()
_Util_Log("Установлено: " & (($g_sVerCur = "") ? "версия не читается" : $g_sVerCur) & " в '" & $g_sTargetPath & "'")

If Not $g_bSilent Then _RunLauncherFlow()

_LaunchVSCode()
Exit


; ============================================================
; GUI построение
; ============================================================

; Маленькое окно проверки: без кнопок, поверх остальных, без кнопки на панели задач.
Func _SplashGUI()
	$g_hSplash = GUICreate($gc_sAppName, $gc_iSplashWidth, $gc_iSplashHeight, -1, -1, _
			BitOR($WS_POPUP, $WS_CAPTION, $WS_SYSMENU), $WS_EX_TOPMOST)
	GUISetBkColor($gc_iClrBg, $g_hSplash)
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hSplash)
	_GUISetDarkTitleBar($g_hSplash)

	Local $iWidth = $gc_iSplashWidth - 2 * $gc_iPad
	$g_iSplashText = _DarkLabel("Проверка обновлений...", $gc_iPad, $gc_iPad, $iWidth, 20, $gc_iClrText)
	$g_iSplashSub = _DarkLabel("Update.code.visualstudio.com", $gc_iPad, 46, $iWidth, 18, $gc_iClrDim, -1, $gc_nFontCaption)
	$g_iSplashBarBg = _DarkLabel("", $gc_iPad, $gc_iSplashActionTop + 13, $iWidth, 6, $gc_iClrText, $gc_iClrBarBg)
	$g_iSplashBar = _DarkLabel("", $gc_iPad, $gc_iSplashActionTop + 13, 0, 6, $gc_iClrText, $gc_iClrBar)

	GUISetState(@SW_SHOW, $g_hSplash)
EndFunc   ;==>_SplashGUI


; Основное окно обновления. Шаги рисуются столбиком: маркер, название, подстрочник.
Func _MainGUI()
	; высота окна выводится из числа шагов, чтобы не подгонять её руками при правках списка
	$g_iBarTop = $gc_iStepTop + UBound($g_aStepTitle) * $gc_iStepPitch + 14
	$g_iButtonTop = $g_iBarTop + 52

	$g_hMain = GUICreate($gc_sTitle, $gc_iMainWidth, $g_iButtonTop + $gc_iBtnHeight + 16, -1, -1, _
			BitOR($WS_POPUP, $WS_CAPTION, $WS_SYSMENU))
	GUISetBkColor($gc_iClrBg, $g_hMain)
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hMain)
	_GUISetDarkTitleBar($g_hMain)

	; --- Шапка: новая версия отдельной меткой, чтобы выделить её акцентом ---
	; Ширину -1 (по тексту) метка считает по шрифту GUI, а не по своему собственному,
	; поэтому крупный шрифт ставим на GUI до создания и возвращаем обратно после.
	; Пробелы вокруг стрелки берём из самого текста, иначе к ним прибавляется
	; запас автоширины Label и версии расползаются
	GUISetFont($gc_nFontTitle, 300, 0, "Segoe UI", $g_hMain)
	$g_iHero = _DarkLabel($g_sVerCur & " ", $gc_iBarLeft, 16, 10, 30, $gc_iClrText)
	$g_iHeroArrow = _DarkLabel(ChrW(0x2192) & " ", $gc_iBarLeft, 16, 10, 30, $gc_iClrDim)

	GUISetFont($gc_nFontTitle, 600, 0, "Segoe UI", $g_hMain)
	$g_iHeroNew = _DarkLabel($g_sVerNew, $gc_iBarLeft, 16, 10, 30, $gc_iClrRun)
	GUICtrlSetFont($g_iHeroNew, $gc_nFontTitle, 600, 0, "Segoe UI")

	_LayoutRow($gc_iBarLeft, 16, 30, $g_iHero, $g_sVerCur & " ", $g_iHeroArrow, ChrW(0x2192) & " ", $g_iHeroNew, $g_sVerNew)

	; Подзаголовок под версиями: путь, имя архива, размер - через точки-разделители
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hMain)
	Local $sDot = "  " & ChrW(0x2022) & "  "
	$g_iHeroSub = _DarkLabel($g_sTargetPath & $sDot & _Util_FileName($g_sZipFile) & $sDot & _FormatSize($g_iZipSize), _
			$gc_iBarLeft, 54, $gc_iBarWidth, 18, $gc_iClrDim, -1, $gc_nFontCaption)

	; --- Шаги ---
	Local $iTop = $gc_iStepTop
	For $i = 0 To UBound($g_aStepTitle) - 1
		$g_aMarker[$i] = _DarkLabel($gc_sMarkWait, 22, $iTop, 18, 20, $gc_iClrWait)
		$g_aStepLabel[$i] = _DarkLabel($g_aStepTitle[$i], 44, $iTop, 260, 20, $gc_iClrWait)
		; серый мельче белого, поэтому строку сдвигаем вниз - иначе тексты не на одной линии
		$g_aStepSub[$i] = _DarkLabel("", $gc_iStepInfoLeft, $iTop + 2, $gc_iBtnRight - $gc_iStepInfoLeft, 18, _
				$gc_iClrDim, -1, $gc_nFontCaption, 400, $SS_RIGHT)
		$iTop += $gc_iStepPitch
	Next

	; --- Прогресс и статус ---
	$g_iBarBg = _DarkLabel("", $gc_iBarLeft, $g_iBarTop, $gc_iBarWidth, $gc_iBarHeight, $gc_iClrText, $gc_iClrBarBg)
	$g_iBar = _DarkLabel("", $gc_iBarLeft, $g_iBarTop, 0, $gc_iBarHeight, $gc_iClrText, $gc_iClrBar)
	$g_iStatus = _DarkLabel("", $gc_iBarLeft, $g_iBarTop + 16, 200, 20, $gc_iClrText)
	$g_iStatusInfo = _DarkLabel("", $gc_iBarLeft + 200, $g_iBarTop + 18, $gc_iBarWidth - 200, 18, _
			$gc_iClrDim, -1, $gc_nFontCaption, 400, $SS_RIGHT)

	; --- Кнопки: 'Повторить' прячем до ошибки, обновление уже подтверждено в первом окне ---
	$g_iBtnMain = _DarkButton("Повторить", $gc_iBtnRight, $g_iButtonTop, True)
	$g_iBtnAlt = _DarkButton("Отмена", $gc_iBtnRight, $g_iButtonTop)
	_LayoutButtons("work")

	GUISetState(@SW_SHOW, $g_hMain)
EndFunc   ;==>_MainGUI


Func _DefineEvents()
	If $g_hSplash <> 0 Then
		GUISetOnEvent($GUI_EVENT_CLOSE, "_OnEvent_GUI_EVENT_CLOSE", $g_hSplash)
		If $g_iSplashBtnUpdate <> 0 Then GUICtrlSetOnEvent($g_iSplashBtnUpdate, "_OnEvent_ChoiceUpdate")
		If $g_iSplashBtnRun <> 0 Then GUICtrlSetOnEvent($g_iSplashBtnRun, "_OnEvent_ChoiceRun")
	EndIf

	If $g_hMain <> 0 Then
		GUISetOnEvent($GUI_EVENT_CLOSE, "_OnEvent_GUI_EVENT_CLOSE", $g_hMain)
		GUICtrlSetOnEvent($g_iBtnAlt, "_OnEvent_ButtonAlt")
		GUICtrlSetOnEvent($g_iBtnMain, "_OnEvent_ButtonMain")
	EndIf
EndFunc   ;==>_DefineEvents


; ============================================================
; Обработчики событий
; ============================================================

Func _OnEvent_ChoiceUpdate()
	$g_iChoice = 1
EndFunc   ;==>_OnEvent_ChoiceUpdate


Func _OnEvent_ChoiceRun()
	$g_iChoice = 2
EndFunc   ;==>_OnEvent_ChoiceRun


; Вторая кнопка основного окна: до начала переноса файлов это 'Отмена',
; после успеха - 'Закрыть', после ошибки - 'Запустить как есть'.
; Дочерние процессы (curl, 7-Zip) закрывают сами модули, когда видят отмену
; через колбэк _IsAborted - здесь достаточно поднять флаг.
Func _OnEvent_ButtonAlt()
	If $g_bCancelLocked Then Return
	$g_bCancel = True
EndFunc   ;==>_OnEvent_ButtonAlt


Func _OnEvent_ButtonMain()
	If Not _IsButtonEnabled($g_iBtnMain) Then Return
	$g_iChoice = 1
EndFunc   ;==>_OnEvent_ButtonMain


Func _OnEvent_GUI_EVENT_CLOSE()
	If @GUI_WinHandle = $g_hMain And $g_bCancelLocked Then Return ; на переносе файлов закрываться нельзя
	_OnEvent_ButtonAlt()
	If @GUI_WinHandle = $g_hSplash Then $g_iChoice = 2
EndFunc   ;==>_OnEvent_GUI_EVENT_CLOSE


; ============================================================
; Сценарий лаунчера
; ============================================================

; Проверка обновления в маленьком окне, при наличии - вопрос и переход в основное окно.
Func _RunLauncherFlow()
	_SplashGUI()
	_DefineEvents()

	Local $aUpd = _Net_CheckUpdate($gc_sUpdateApi, $gc_iCheckTimeout, "_SplashPulse")
	Local $iErr = @error
	If $iErr Then
		; ссылка на чужой хост - это не сбой сети, о таком надо сказать прямо
		If $iErr = 4 Then
			_Util_Log("ОТКАЗ: сервер вернул ссылку на неизвестный хост")
			_SplashSetState("Ссылка не от Microsoft", "Обновление отменено, запуск " & $g_sVerCur & "...", $gc_iClrWarn)
			_Wait(2200, $g_hSplash)
			Return _CloseSplash()
		EndIf

		_Util_Log("Сервер обновлений недоступен (код " & $iErr & ")")
		_SplashSetState("Сервер обновлений недоступен", "Запуск текущей версии " & $g_sVerCur & "...", $gc_iClrWarn)
		_Wait(900, $g_hSplash)
		Return _CloseSplash()
	EndIf

	$g_sVerNew = $aUpd[0]
	$g_sUrl = $aUpd[1]
	$g_sHash = $aUpd[2]
	$g_iVerStamp = $aUpd[3]
	_Util_Log("Сервер предлагает " & $g_sVerNew)

	If _CompareVersions($g_sVerNew, $g_sVerCur) <= 0 Then
		_SplashSetState("Установлена последняя версия " & $g_sVerCur, "Запуск VS Code...", $gc_iClrOk)
		_Wait(700, $g_hSplash)
		Return _CloseSplash()
	EndIf

	; Свой же процесс удержит папку от удаления, если программа лежит внутри неё
	If _Util_IsInsidePath(@ScriptDir, $g_sTargetPath) Then
		_Util_Log("ОТКАЗ: программа лежит внутри обновляемой папки")
		_SplashSetState("Обновление невозможно", "VSCodePUPD лежит внутри папки VS Code", $gc_iClrWarn)
		_Wait(2200, $g_hSplash)
		Return _CloseSplash()
	EndIf

	; Пока из папки работает хоть один процесс, её не переименовать и не удалить
	Local $sBusy = _BusyProcesses($g_sTargetPath)
	If $sBusy <> "" Then
		_Util_Log("ОТКАЗ: папка занята процессами " & $sBusy)
		_SplashSetState("Обновление пропущено", "Закройте: " & $sBusy, $gc_iClrWarn)
		_Wait(2200, $g_hSplash)
		Return _CloseSplash()
	EndIf

	$g_sZipFile = $g_sWorkDir & "\" & _Util_FileName($g_sUrl)
	$g_iZipSize = _Net_GetRemoteSize($g_sUrl, 5000, "_SplashPulse")

	; Места должно хватить и на архив, и на обе версии рядом
	Local $sSpace = _CheckFreeSpace()
	If $sSpace <> "" Then
		_Util_Log("ОТКАЗ: " & $sSpace)
		_SplashSetState("Не хватает места на диске", $sSpace, $gc_iClrWarn)
		_Wait(3000, $g_hSplash)
		Return _CloseSplash()
	EndIf

	If _AskUpdate() = 2 Then
		_Util_Log("Пользователь отказался от обновления")
		Return _CloseSplash()
	EndIf

	_CloseSplash()
	_MainGUI()
	_DefineEvents()
	_RunUpdate()
EndFunc   ;==>_RunLauncherFlow


; Хватит ли места на архив и на обе версии VS Code рядом.
; '' - хватает или проверить не удалось, иначе текст для показа.
Func _CheckFreeSpace()
	If $g_iZipSize <= 0 Then Return ""

	Local $nNeed = $g_iZipSize * $gc_nSpaceFactor
	Local $nFree = _Util_FreeSpace($g_sWorkDir)
	If $nFree < 0 Then Return "" ; сетевой путь или том не определился, мешать не будем

	If $nFree >= $nNeed Then Return ""
	Return "нужно около " & _FormatSize($nNeed) & ", свободно " & _FormatSize($nFree)
EndFunc   ;==>_CheckFreeSpace


; Пауза, на которой окно продолжает отвечать: перерисовка, подсветка кнопок
; и крестик работают. Обычный Sleep морозит интерфейс на всё время ожидания.
Func _Wait($iMs, $hWnd = 0)
	Local $iTimer = TimerInit()
	While TimerDiff($iTimer) < $iMs
		Sleep(20)
		If $hWnd <> 0 Then _UpdateHover($hWnd)
		If $g_bCancel Then Return ; пользователь закрыл окно, ждать больше нечего
	WEnd
EndFunc   ;==>_Wait


; Разворачивает маленькое окно в вопрос 'Обновить / Запустить как есть'.
; Возвращает 1 - обновлять, 2 - запускать текущую версию.
Func _AskUpdate()
	Local $sSize = ($g_iZipSize > 0) ? "Загрузка " & _FormatSize($g_iZipSize) : "Загрузка архива"
	Local $sDone = _DownloadedPart()
	If $sDone <> "" Then $sSize &= ", уже загружено " & $sDone

	; Заголовок из трёх меток, склеенных по фактической ширине текста: пробелы
	; должны читаться как в обычной строке, а не как отступы между контролами
	GUICtrlSetState($g_iSplashText, $GUI_HIDE)
	Local $sHead = "Доступна версия ", $sTail = "  текущая " & $g_sVerCur

	Local $iHead = _DarkLabel($sHead, $gc_iPad, $gc_iPad, 10, 20, $gc_iClrText)
	Local $iVersion = _DarkLabel($g_sVerNew, $gc_iPad, $gc_iPad, 10, 20, $gc_iClrRun)
	GUICtrlSetFont($iVersion, $gc_nFontBody, 600, 0, "Segoe UI")
	Local $iTail = _DarkLabel($sTail, $gc_iPad, $gc_iPad, 10, 20, $gc_iClrText)

	_LayoutRow($gc_iPad, $gc_iPad, 20, $iHead, $sHead, $iVersion, $g_sVerNew, $iTail, $sTail)

	; Полоса на время вопроса не нужна, вместо неё - кнопки.
	; Просветы одинаковые: заголовок - подзаголовок - кнопки - нижнее поле.
	GUICtrlSetState($g_iSplashBarBg, $GUI_HIDE)
	GUICtrlSetState($g_iSplashBar, $GUI_HIDE)
	GUICtrlSetData($g_iSplashSub, $sSize)
	; Окно не меняет размер между состояниями: кнопки встают в ту же зону,
	; где при проверке была полоса прогресса
	$g_iSplashBtnUpdate = _DarkButton("Обновить", 0, $gc_iSplashActionTop, True)
	$g_iSplashBtnRun = _DarkButton("Пропустить", 0, $gc_iSplashActionTop)
	_PlaceButtons($gc_iSplashWidth - $gc_iPad, $gc_iSplashActionTop, $g_iSplashBtnUpdate, $g_iSplashBtnRun)
	_DefineEvents()

	$g_iChoice = 0
	While $g_iChoice = 0
		Sleep(30)
		_UpdateHover($g_hSplash)
	WEnd

	Return $g_iChoice
EndFunc   ;==>_AskUpdate


; Полный цикл обновления в основном окне. Каждый шаг сам двигает общий прогресс.
; Повторы идут циклом, а не рекурсией: раньше каждое 'Повторить' углубляло стек.
Func _RunUpdate()
	While 1
		Local $bRetry = _RunUpdateOnce()
		If Not $bRetry Then ExitLoop
		_ResetSteps()
	WEnd

	If $g_hMain <> 0 Then
		GUIDelete($g_hMain)
		$g_hMain = 0
	EndIf
EndFunc   ;==>_RunUpdate


; Один проход обновления. True - пользователь просит повторить после ошибки.
Func _RunUpdateOnce()
	_SetStep(0, "done", _ReleaseLine())
	_SetProgressStep($g_iStepDownload, 0)

	; --- Загрузка и сверка контрольной суммы: один шаг, сумма без своего пункта ---
	_SetStep($g_iStepDownload, "run")
	_SetStatus("Загрузка архива...")
	_DownloadArchive()
	If @error Then
		Local $sStopped = _DownloadedPercent()
		If $g_bCancel Then Return _FailStep($g_iStepDownload, "Загрузка отменена", $sStopped)
		Return _FailStep($g_iStepDownload, "Ошибка загрузки, проверьте соединение.", $sStopped)
	EndIf

	_SetStatus("Проверка контрольной суммы...")
	GUICtrlSetData($g_aStepSub[$g_iStepDownload], "")
	Local $bMatch = _Arc_VerifySha256($g_sZipFile, $g_sHash, "_OnHashProgress", "_IsAborted")
	Local $iHashErr = @error
	If $iHashErr = 2 Then Return _FailStep($g_iStepDownload, "Проверка отменена", "")
	If $iHashErr Then Return _FailStep($g_iStepDownload, "Не удалось прочитать архив", "проверьте, не занят ли файл другой программой")
	If Not $bMatch Then
		_Util_Log("ОШИБКА: SHA-256 не совпал, архив удалён")
		FileDelete($g_sZipFile) ; битую докачку продолжать нельзя, начинаем с нуля
		Return _FailStep($g_iStepDownload, "Архив повреждён", "SHA-256 не совпал с ответом сервера, файл удалён")
	EndIf
	_SetStep($g_iStepDownload, "done", $g_sDownloadSummary)
	_Util_Log("Архив загружен и проверен: " & $g_sDownloadSummary)

	; Загрузка идёт минутами, за это время редактор могли успеть запустить,
	; а занятую папку не переименовать - проверяем ещё раз перед сносом
	Local $sBusy = _BusyProcesses($g_sTargetPath)
	If $sBusy <> "" Then Return _FailStep($g_iStepRemove, "Папка VS Code занята", "закройте: " & $sBusy)

	; С этого места отменять нельзя: папка Data уже уедет из своего места
	$g_bCancelLocked = True
	_SetButtonEnabled($g_iBtnAlt, False)

	; --- Вынос папки данных: только если она лежит внутри каталога VS Code ---
	Local $sBackup = ""
	If $g_iStepBackup >= 0 Then
		_SetStep($g_iStepBackup, "run")
		_SetStatus("Перенос папки данных...")
		$sBackup = _BackupUserData()
		If @error Then
			_Util_Log("ОШИБКА: не удалось вынести папку данных, " & $sBackup)
			Return _FailStep($g_iStepBackup, "Не удалось перенести папку данных", $sBackup)
		EndIf
		_SetStep($g_iStepBackup, "done", ($sBackup = "") _
				? "папки не было" _
				: _FitPath($g_aStepSub[$g_iStepBackup], $sBackup))
	EndIf

	; --- Удаление старой версии ---
	_SetStep($g_iStepRemove, "run")
	_SetStatus("Удаление старой версии в корзину...")
	If Not _RemoveOldVersion() Then
		_Util_Log("ОШИБКА: не удалось удалить старую версию")
		Local $bBack = _RestoreUserData($sBackup)
		Return _FailStep($g_iStepRemove, "Не удалось удалить старую версию", _
				($sBackup = "") ? "" : ($bBack ? "папка данных возвращена на место" : "папка данных осталась в '" & $sBackup & "'"))
	EndIf
	_SetStep($g_iStepRemove, "done", "'VS Code " & $g_sVerCur & "' в корзине")

	; --- Распаковка ---
	_SetStep($g_iStepUnpack, "run")
	_SetStatus("Распаковка архива...")
	If Not _UnpackArchive() Then
		; Возвращать данные в наполовину распакованный каталог нельзя: следующая
		; попытка распаковки перемешает их с новой сборкой. Бэкап остаётся на месте,
		; путь к нему записан в ini и подхватится при следующем запуске.
		_Util_Log("ОШИБКА: распаковка не удалась, бэкап оставлен в '" & $sBackup & "'")
		Return _FailStep($g_iStepUnpack, "Ошибка распаковки", _
				($sBackup = "") ? "восстановите VS Code из корзины" : "данные ждут в '" & _Util_FileName($sBackup) & "'")
	EndIf
	_SetStep($g_iStepUnpack, "done", $g_sUnpackSummary)

	; --- Возврат папки данных ---
	If $g_iStepRestore >= 0 Then
		_SetStep($g_iStepRestore, "run")
		_SetStatus("Возврат папки данных...")
		If $sBackup <> "" And Not _RestoreUserData($sBackup) Then
			_Util_Log("ОШИБКА: не удалось вернуть папку данных из '" & $sBackup & "'")
			Return _FailStep($g_iStepRestore, "Папка данных осталась в " & _Util_FileName($sBackup), _
					"перенесите её в " & $g_sDataPath & " вручную")
		EndIf
		_SetStep($g_iStepRestore, "done", ($sBackup = "") ? "" : _FitPath($g_aStepSub[$g_iStepRestore], $g_sDataPath))
	EndIf

	; --- Проверка и запуск ---
	_SetStep($g_iStepLaunch, "run")
	Local $sVerAfter = _GetVSCodeVers()
	If $sVerAfter = "" Or _CompareVersions($sVerAfter, $g_sVerCur) <= 0 Then
		_Util_Log("ОШИБКА: после распаковки версия '" & $sVerAfter & "' не новее '" & $g_sVerCur & "'")
		Return _FailStep($g_iStepLaunch, "После распаковки версия не изменилась: " & $sVerAfter, _
				"архив мог быть собран не для этой платформы")
	EndIf

	FileRecycle($g_sZipFile)
	IniDelete($gc_sIniFile, "State")
	_SetStep($g_iStepLaunch, "done")
	_SetProgress(100)
	_SetStatus("Обновлено до " & $sVerAfter & ", запуск VS Code...")
	_LayoutButtons("done")
	$g_sVerCur = $sVerAfter
	_Util_Log("ГОТОВО: обновлено до " & $sVerAfter)

	_Wait(1200, $g_hMain)
	Return False
EndFunc   ;==>_RunUpdateOnce


; Показывает ошибку шага и ждёт решения. True - повторить, False - выйти к запуску.
Func _FailStep($iStep, $sMsg, $sSub = "")
	_SetStep($iStep, "err", $sSub)
	_SetStatus($sMsg, True)
	GUICtrlSetBkColor($g_iBar, $gc_iClrBarErr)

	_LayoutButtons("error")
	$g_bCancel = False
	$g_bCancelLocked = False

	$g_iChoice = 0
	While $g_iChoice = 0 And Not $g_bCancel
		Sleep(30)
		_UpdateHover($g_hMain)
	WEnd

	Return ($g_iChoice = 1)
EndFunc   ;==>_FailStep


; ============================================================
; Настройки и первый запуск
; ============================================================

; Окно первого запуска: путь к VS Code и что программа поняла про папку данных.
; True - настройки сохранены, False - пользователь отказался.
Func _SetupGUI()
	Local Const $iMinWidth = 440 ; ниже уже неудобно вводить путь
	Local $iWidth = 900 ; с запасом: окно ужмётся по факту после замера строк

	$g_hSetup = GUICreate($gc_sTitle & " - Первый запуск", $iWidth, 600, -1, -1, _
			BitOR($WS_POPUP, $WS_CAPTION, $WS_SYSMENU), $WS_EX_TOPMOST)
	GUISetBkColor($gc_iClrBg, $g_hSetup)
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hSetup)
	_GUISetDarkTitleBar($g_hSetup)

	Local $aLines[0][2] ; [ControlID, текст] - по ним считаем нужную ширину окна
	Local $iY = $gc_iPad

	; --- Что это и зачем ---
	Local $aAbout[3] = [ _
			"Портативный Visual Studio Code из коробки не обновляется автоматически.", _
			"Приходится качать архив и переносить в него пользовательские настройки", _
			"вручную. Теперь VSCodePUPD берёт это на себя."]
	$iY = _SetupBlock($aLines, "VSCodePUPD", $aAbout, $iY)

	; --- Что программа делает с вашими данными ---
	Local $aSafe[4] = [ _
			"Обновление начинается только по вашей команде. Архив скачивается из", _
			"официального источника Microsoft. Настройки и расширения переносятся", _
			"целиком. Старые версии и архивы удаляются только через корзину."]
	$iY = _SetupBlock($aLines, "Насколько это безопасно", $aSafe, $iY + 10)

	; --- Папка VS Code ---
	_SetupAddLine($aLines, _DarkLabel("Папка VS Code", $gc_iPad, $iY, 400, 20, $gc_iClrText), "Папка VS Code")
	$iY += 24

	$g_iSetupInput = GUICtrlCreateInput($g_sTargetPath, $gc_iPad, $iY, 100, $gc_iBtnHeight)
	GUICtrlSetBkColor($g_iSetupInput, 0x2D2D2D)
	GUICtrlSetColor($g_iSetupInput, $gc_iClrText)
	GUICtrlSetFont($g_iSetupInput, $gc_nFontBody, 400, 0, "Segoe UI")
	$g_iSetupBrowse = _DarkButton("Обзор...", $gc_iPad, $iY) ; встанет по правому краю после замера
	Local $iInputTop = $iY
	$iY += $gc_iBtnHeight + 14

	$g_iSetupData = _DarkLabel("", $gc_iPad, $iY, 600, 20, $gc_iClrText)
	$iY += 20 + 16

	$g_iSetupSave = _DarkButton("Применить", $gc_iPad, $iY, True)
	$g_iSetupCancel = _DarkButton("Отмена", $gc_iPad, $iY)

	; Эти строки появятся позже, но окно не должно из-за них обрезать текст
	Local $aData = _DetectDataPath($g_sTargetPath)
	_SetupAddLine($aLines, $g_iSetupData, $gc_sDataPrefix & $aData[0])

	; --- Окно по содержимому: ширина по самой длинной строке, высота по последнему ряду ---
	Local $iTextWidth = $iMinWidth - 2 * $gc_iPad
	For $i = 0 To UBound($aLines) - 1
		Local $iLine = _TextWidth($aLines[$i][0], $aLines[$i][1])
		If $iLine > $iTextWidth Then $iTextWidth = $iLine
	Next

	$iTextWidth += 30 ; немного воздуха справа, иначе текст упирается в край
	$iWidth = $iTextWidth + 2 * $gc_iPad
	Local $iHeight = $iY + $gc_iBtnHeight + $gc_iPad
	_ResizeClient($g_hSetup, $iWidth, $iHeight)

	For $i = 0 To UBound($aLines) - 1
		Local $aPos = ControlGetPos($g_hSetup, "", $aLines[$i][0])
		GUICtrlSetPos($aLines[$i][0], $gc_iPad, $aPos[1], $iTextWidth, $aPos[3])
	Next

	GUICtrlSetPos($g_iSetupInput, $gc_iPad, $iInputTop, $iTextWidth - $gc_iBtnMinWidth - $gc_iBtnGap, $gc_iBtnHeight)
	GUICtrlSetPos($g_iSetupBrowse, $iWidth - $gc_iPad - $gc_iBtnMinWidth, $iInputTop, $gc_iBtnMinWidth, $gc_iBtnHeight)
	Local $aDataPos = ControlGetPos($g_hSetup, "", $g_iSetupData)
	GUICtrlSetPos($g_iSetupData, $gc_iPad, $aDataPos[1], $iTextWidth, 20)
	_PlaceButtons($iWidth - $gc_iPad, $iY, $g_iSetupSave, $g_iSetupCancel)

	GUISetOnEvent($GUI_EVENT_CLOSE, "_OnEvent_SetupCancel", $g_hSetup)
	GUICtrlSetOnEvent($g_iSetupBrowse, "_OnEvent_SetupBrowse")
	GUICtrlSetOnEvent($g_iSetupSave, "_OnEvent_SetupSave")
	GUICtrlSetOnEvent($g_iSetupCancel, "_OnEvent_SetupCancel")

	_SetupRefresh()
	GUISetState(@SW_SHOW, $g_hSetup)

	; Путь можно и вписать руками, событий об этом Input не шлёт - следим сами
	Local $sLast = GUICtrlRead($g_iSetupInput)
	$g_iChoice = 0
	While $g_iChoice = 0
		Sleep(30)
		_UpdateHover($g_hSetup)
		If GUICtrlRead($g_iSetupInput) <> $sLast Then
			$sLast = GUICtrlRead($g_iSetupInput)
			_SetupRefresh()
		EndIf
	WEnd

	Local $bSaved = ($g_iChoice = 1)
	If $bSaved Then
		$g_sTargetPath = GUICtrlRead($g_iSetupInput)
		IniWrite($gc_sIniFile, "Paths", "TargetPath", $g_sTargetPath)
	EndIf

	GUIDelete($g_hSetup)
	$g_hSetup = 0
	$g_iSetupBrowse = 0
	$g_iSetupSave = 0
	$g_iSetupCancel = 0
	ReDim $g_aHotBtn[0][4]
	_UpdateHover(0, True)

	Return $bSaved
EndFunc   ;==>_SetupGUI


; Блок 'заголовок + строки пояснения'. Возвращает Y под блоком.
Func _SetupBlock(ByRef $aLines, $sTitle, ByRef $aText, $iY)
	GUISetFont($gc_nFontBody, 600, 0, "Segoe UI", $g_hSetup)
	_SetupAddLine($aLines, _DarkLabel($sTitle, $gc_iPad, $iY, 400, 20, $gc_iClrText), $sTitle)
	$iY += 24

	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hSetup)
	For $i = 0 To UBound($aText) - 1
		_SetupAddLine($aLines, _DarkLabel($aText[$i], $gc_iPad, $iY, 400, 18, $gc_iClrDim, -1, $gc_nFontCaption), $aText[$i])
		$iY += 18
	Next

	Return $iY
EndFunc   ;==>_SetupBlock


; Запоминает строку, чтобы потом померить её ширину и подогнать окно
Func _SetupAddLine(ByRef $aLines, $iCtrl, $sText)
	Local $iIndex = UBound($aLines)
	ReDim $aLines[$iIndex + 1][2]
	$aLines[$iIndex][0] = $iCtrl
	$aLines[$iIndex][1] = $sText
EndFunc   ;==>_SetupAddLine


; Пересчитывает строку о папке данных под текущий путь в поле ввода
Func _SetupRefresh()
	Local $sPath = StringStripWS(GUICtrlRead($g_iSetupInput), 3)

	If Not _IsVSCodeFolder($sPath) Then
		GUICtrlSetData($g_iSetupData, "Code.exe в этой папке не найден")
		GUICtrlSetColor($g_iSetupData, $gc_iClrWarn)
		_SetButtonEnabled($g_iSetupSave, False)
		Return
	EndIf

	Local $aData = _DetectDataPath($sPath)
	GUICtrlSetData($g_iSetupData, _FitPath($g_iSetupData, $aData[0], $gc_sDataPrefix))
	GUICtrlSetColor($g_iSetupData, $gc_iClrText)

	_SetButtonEnabled($g_iSetupSave, True)
EndFunc   ;==>_SetupRefresh


; Путь в кавычках-ёлочках по ширине метки: не влезает - срезаем начало
; по границе папки и начинаем с многоточия. Одна функция на оба окна:
; раньше их было две с разными алгоритмами обрезки.
;
; $iCtrl задаёт и ширину, и шрифт замера, поэтому окно ищем по самому контролу.
Func _FitPath($iCtrl, $sPath, $sPrefix = "")
	Local $sFull = $sPrefix & "'" & $sPath & "'"

	Local $aPos = ControlGetPos(_WinAPI_GetParent(GUICtrlGetHandle($iCtrl)), "", $iCtrl)
	If Not IsArray($aPos) Or _TextWidth($iCtrl, $sFull) <= $aPos[2] Then Return $sFull

	; Сначала по границам папок: '...\Code\data' читается лучше обрубка посреди слова
	Local $sCut = $sPath
	While StringInStr($sCut, '\')
		$sCut = StringTrimLeft($sCut, StringInStr($sCut, '\'))
		If _TextWidth($iCtrl, $sPrefix & "'...\" & $sCut & "'") <= $aPos[2] Then _
				Return $sPrefix & "'...\" & $sCut & "'"
	WEnd

	; Разделителей не осталось, а строка всё ещё не влезает - режем посимвольно
	While StringLen($sCut) > 12 And _TextWidth($iCtrl, $sPrefix & "'..." & $sCut & "'") > $aPos[2]
		$sCut = StringTrimLeft($sCut, 4)
	WEnd

	Return $sPrefix & "'..." & $sCut & "'"
EndFunc   ;==>_FitPath


; Имена процессов, чьи исполняемые файлы лежат внутри папки: пока они живы,
; папку не переименовать и не удалить. Проверяем по пути, а не по имени -
; VS Code тянет за собой node из расширений, терминалы, git и прочее.
Func _BusyProcesses($sFolder)
	Local $aList = ProcessList()
	If @error Then Return ""

	Local $sNames = "", $iCount = 0
	For $i = 1 To $aList[0][0]
		If Not _Util_IsInsidePath(_ProcessPath($aList[$i][1]), $sFolder) Then ContinueLoop
		If StringInStr($sNames, $aList[$i][0]) Then ContinueLoop

		$sNames &= ($sNames = "") ? $aList[$i][0] : ", " & $aList[$i][0]
		$iCount += 1
		If $iCount >= 3 Then
			$sNames &= " и другие процессы"
			ExitLoop
		EndIf
	Next

	Return $sNames
EndFunc   ;==>_BusyProcesses


; Полный путь к исполняемому файлу процесса. Спрашиваем через
; QueryFullProcessImageName: ограниченного доступа хватает и без прав администратора.
Func _ProcessPath($iPID)
	Local $aProcess = DllCall("kernel32.dll", "handle", "OpenProcess", _
			"dword", $PROCESS_QUERY_LIMITED_INFORMATION, _
			"bool", False, _
			"dword", $iPID)
	If @error Or Not $aProcess[0] Then Return ""

	Local $tPath = DllStructCreate("wchar[4096]")
	Local $aCall = DllCall("kernel32.dll", "bool", "QueryFullProcessImageNameW", _
			"handle", $aProcess[0], _
			"dword", 0, _
			"struct*", $tPath, _
			"dword*", 4096)
	Local $bOk = Not @error And $aCall[0]
	_WinAPI_CloseHandle($aProcess[0])

	Return $bOk ? DllStructGetData($tPath, 1) : ""
EndFunc   ;==>_ProcessPath


Func _OnEvent_SetupBrowse()
	Local $sStart = GUICtrlRead($g_iSetupInput)
	If Not FileExists($sStart) Then $sStart = _Util_ParentDir(@ScriptDir)

	Local $sPath = FileSelectFolder("Папка портативного VS Code", "", 0, $sStart, $g_hSetup)
	If @error Then Return

	GUICtrlSetData($g_iSetupInput, $sPath)
	_SetupRefresh()
EndFunc   ;==>_OnEvent_SetupBrowse


Func _OnEvent_SetupSave()
	If Not _IsButtonEnabled($g_iSetupSave) Then Return
	$g_iChoice = 1
EndFunc   ;==>_OnEvent_SetupSave


Func _OnEvent_SetupCancel()
	$g_iChoice = 2
EndFunc   ;==>_OnEvent_SetupCancel

; Читает пути из ini рядом с программой. Если настроек нет или папка не годится,
; показывает окно первого запуска.
Func _LoadConfig()
	Local $sSaved = IniRead($gc_sIniFile, "Paths", "TargetPath", "")
	$g_sTargetPath = ($sSaved <> "") ? $sSaved : _GuessTargetPath()

	; Прерванный прогон разбираем до _ApplyPaths: вынесенная папка данных сбивает
	; определение их места, и возврат ушёл бы не туда
	_RecoverInterrupted()

	; Окно первого запуска показываем и когда папка найдена сама: человек должен
	; увидеть, что именно программа собралась обновлять, и подтвердить это.
	If $sSaved = "" Or Not _IsVSCodeFolder($g_sTargetPath) Then
		; В тихом режиме окон не показываем: разбираться будет _LaunchVSCode
		If $g_bSilent Then Return _ApplyPaths()
		If Not _SetupGUI() Then Exit ; отказались - обновлять нечего
	EndIf

	_ApplyPaths()
EndFunc   ;==>_LoadConfig


; Собирает список шагов: без папки данных внутри VS Code переносить нечего,
; и два шага из семи просто не нужны.
Func _BuildSteps()
	Local $iCount = 0, $nSkipped = 0
	Local $aTitle[UBound($gc_aStepPlan)], $aWeight[UBound($gc_aStepPlan)]

	; Индексы шагов больше не проставляются руками: они выводятся из ключей плана
	$g_iStepDownload = -1
	$g_iStepBackup = -1
	$g_iStepRemove = -1
	$g_iStepUnpack = -1
	$g_iStepRestore = -1
	$g_iStepLaunch = -1

	For $i = 0 To UBound($gc_aStepPlan) - 1
		If $gc_aStepPlan[$i][3] And Not $g_bDataInside Then
			$nSkipped += $gc_aStepPlan[$i][2] ; вес пропущенного шага раздадим остальным
			ContinueLoop
		EndIf

		$aTitle[$iCount] = $gc_aStepPlan[$i][1]
		$aWeight[$iCount] = $gc_aStepPlan[$i][2]

		Switch $gc_aStepPlan[$i][0]
			Case "download"
				$g_iStepDownload = $iCount
			Case "backup"
				$g_iStepBackup = $iCount
			Case "remove"
				$g_iStepRemove = $iCount
			Case "unpack"
				$g_iStepUnpack = $iCount
			Case "restore"
				$g_iStepRestore = $iCount
			Case "launch"
				$g_iStepLaunch = $iCount
		EndSwitch

		$iCount += 1
	Next

	ReDim $aTitle[$iCount]
	ReDim $aWeight[$iCount]

	; Сумма весов должна остаться сотней, иначе полоса не дойдёт до края
	If $nSkipped > 0 Then
		Local $nTotal = 100 - $nSkipped
		For $i = 0 To $iCount - 1
			$aWeight[$i] = $aWeight[$i] * 100 / $nTotal
		Next
	EndIf

	$g_aStepTitle = $aTitle
	$g_aStepWeight = $aWeight

	ReDim $g_aMarker[$iCount]
	ReDim $g_aStepLabel[$iCount]
	ReDim $g_aStepSub[$iCount]
EndFunc   ;==>_BuildSteps


; Достраивает производные пути от выбранной папки VS Code
Func _ApplyPaths()
	$g_sCodeExe = $g_sTargetPath & "\Code.exe"
	$g_sWorkDir = IniRead($gc_sIniFile, "Paths", "WorkDir", "")
	If $g_sWorkDir = "" Then $g_sWorkDir = _Util_ParentDir($g_sTargetPath) & "\VSCodeUpdate"

	Local $aData = _DetectDataPath($g_sTargetPath)
	$g_sDataPath = $aData[0]
	$g_bDataInside = ($aData[1] = "inside")
EndFunc   ;==>_ApplyPaths


; Где VS Code держит настройки и расширения. Возвращает [путь, вид]:
;   inside       - папка data внутри каталога VS Code, при обновлении её надо уносить
;   portable-env - путь задан переменной VSCODE_PORTABLE, каталог обновления её не трогает
;   profile      - обычная установка: %APPDATA%\Code, обновление архива её не затрагивает
Func _DetectDataPath($sTarget)
	Local $aResult[2]
	Local $sEnv = EnvGet("VSCODE_PORTABLE")
	Local $bEnv = ($sEnv <> "" And FileExists($sEnv))

	; Переменная, указывающая внутрь обновляемой папки - это её собственные данные
	If $bEnv And _Util_IsInsidePath($sEnv, $sTarget) Then
		$aResult[0] = $sEnv
		$aResult[1] = "inside"
		Return $aResult
	EndIf

	; Дальше папка data важнее переменной, хотя сам VS Code решает наоборот.
	; Причина в том, что переменная описывает ЗАПУЩЕННЫЙ экземпляр и легко
	; достаётся по наследству: запусти лаунчер из терминала VS Code - и он
	; получит чужой VSCODE_PORTABLE. Поверь мы ему, данные обновляемой сборки
	; остались бы неопознанными и уехали в корзину вместе со старой версией.
	Local $sInside = $sTarget & "\data"
	If FileExists($sInside) Then
		$aResult[0] = $sInside
		$aResult[1] = "inside"
		Return $aResult
	EndIf

	If $bEnv Then
		$aResult[0] = $sEnv
		$aResult[1] = "portable-env"
		Return $aResult
	EndIf

	$aResult[0] = @AppDataDir & "\Code"
	$aResult[1] = "profile"
	Return $aResult
EndFunc   ;==>_DetectDataPath


Func _IsVSCodeFolder($sPath)
	Return $sPath <> "" And FileExists($sPath & "\Code.exe")
EndFunc   ;==>_IsVSCodeFolder


; Разумное предположение до первой настройки: рядом с программой, затем привычный путь
Func _GuessTargetPath()
	Local $aTry[3] = [ _
			@ScriptDir, _                                   ; программа лежит прямо в папке VS Code
			@ScriptDir & "\VS Code", _                      ; папка VS Code рядом с программой
			_Util_ParentDir(@ScriptDir) & "\VS Code"]            ; программа в соседней папке

	For $i = 0 To UBound($aTry) - 1
		If _IsVSCodeFolder($aTry[$i]) Then Return $aTry[$i]
	Next

	Return ""
EndFunc   ;==>_GuessTargetPath


; ============================================================
; Сеть
; ============================================================









; Загрузка архива силами модуля: сюда сведены колбэки прогресса и отмены.
; @error пробрасывается наружу без изменений.
Func _DownloadArchive()
	If Not FileExists($g_sWorkDir) Then DirCreate($g_sWorkDir)
	If Not FileExists($g_sWorkDir) Then Return SetError(4, 0, 0) ; папку не создать, качать некуда

	Local $nSeconds = _Net_Download($g_sUrl, $g_sZipFile, $g_iZipSize, "_OnDownloadProgress", "_IsAborted")
	Local $iErr = @error
	If $iErr Then
		If $iErr <> 2 Then _Util_Log("ОШИБКА загрузки: код " & $iErr & ", curl " & @extended)
		Return SetError($iErr, @extended, 0)
	EndIf

	; размер сервер мог не сообщить - тогда берём фактический размер файла
	Local $iSize = ($g_iZipSize > 0) ? $g_iZipSize : _Util_FileSizeLive($g_sZipFile)
	$g_sDownloadSummary = ($nSeconds > 0) _
			? _FormatSize($iSize) & " за " & _FormatTime($nSeconds, False) _
			: _FormatSize($iSize) & ", уже был загружен"
	Return 1
EndFunc   ;==>_DownloadArchive


; Распаковка силами модуля, прогресс и отмена - теми же колбэками
Func _UnpackArchive()
	Local $aResult = _Arc_Unpack(@ScriptDir & "\Apps\7z.exe", $g_sZipFile, $g_sTargetPath, _
			"_OnUnpackProgress", "_IsAborted")
	If @error Then
		_Util_Log("ОШИБКА распаковки: код " & @error & ", 7-Zip " & @extended)
		Return False
	EndIf

	$g_sUnpackSummary = _FormatSize($aResult[0]) & " за " & _FormatTime($aResult[1], False)
	_SetStatus("Распаковка архива...")
	Return FileExists($g_sCodeExe)
EndFunc   ;==>_UnpackArchive


Func _OnUnpackProgress($iDone, $iExpected)
	_UpdateHover($g_hMain)
	_SetProgressStep($g_iStepUnpack, $iDone / $iExpected)
	_SetStatus("Распаковка архива...", False, _FormatSizePair($iDone, $iExpected))
EndFunc   ;==>_OnUnpackProgress


; Сверка суммы - часть шага загрузки, поэтому общую полосу не двигает:
; показываем только проценты в строке состояния, чтобы окно не выглядело зависшим.
Func _OnHashProgress($iDone, $iTotal)
	_UpdateHover($g_hMain)
	If $iTotal <= 0 Then Return
	_SetStatus("Проверка контрольной суммы...", False, Int($iDone / $iTotal * 100) & " %")
EndFunc   ;==>_OnHashProgress


; Модули спрашивают об отмене этим колбэком
Func _IsAborted()
	_UpdateHover($g_hMain)
	Return $g_bCancel
EndFunc   ;==>_IsAborted


; Подстрочник шага загрузки: сколько скачано, скорость, остаток времени.
Func _OnDownloadProgress($iDone, $nSpeed)
	Local $sDot = "  " & ChrW(0x2022) & "  "
	Local $sText = _FormatSize($iDone)
	If $g_iZipSize > 0 Then
		$sText = _FormatSizePair($iDone, $g_iZipSize)
		_SetProgressStep($g_iStepDownload, $iDone / $g_iZipSize)
	EndIf

	If $nSpeed > 1024 Then
		$sText &= $sDot & _FormatSize($nSpeed) & "/с"
		If $g_iZipSize > $iDone Then
			$sText &= $sDot & "осталось " & _FormatTime(($g_iZipSize - $iDone) / $nSpeed)
		EndIf
	EndIf

	_SetStatus("Загрузка архива...", False, $sText)
EndFunc   ;==>_OnDownloadProgress




; ============================================================
; Файловые операции
; ============================================================

; Читает версию VS Code из файловой версии Code.exe, '1.134.0.0' → '1.134.0'.
; '' - прочитать не удалось. Раньше здесь был MsgBox и Exit, но после удачной
; распаковки такой выход бросал пользователя без запущенного редактора.
Func _GetVSCodeVers()
	Local $sVers = FileGetVersion($g_sCodeExe)
	If @error Or $sVers = "" Then Return ""
	Return StringRegExpReplace($sVers, '\.\d+$', '')
EndFunc   ;==>_GetVSCodeVers


; Выносит папку Data за пределы каталога VS Code. Возвращает путь к вынесенной папке
; ('' - папки не было). При @error в возврате - текст ошибки для показа.
;
; DirMove при неудаче возвращает 0 и НЕ ставит @error, поэтому проверяем возврат.
; Раньше провал переноса оставался незамеченным, и следующий шаг отправлял
; настройки пользователя в корзину вместе со старой версией.
Func _BackupUserData()
	If Not FileExists($g_sDataPath) Then Return ""

	Local $sBase = _Util_ParentDir($g_sTargetPath) & "\VSCodeUserData " & @MDAY & "." & @MON & "." & StringRight(@YEAR, 2)
	Local $sBackup = $sBase

	; за один день можно обновиться дважды: тогда рядом появится '... 2', '... 3'
	For $i = 2 To 20
		If Not FileExists($sBackup) Then ExitLoop
		$sBackup = $sBase & " " & $i
	Next

	; Метку пишем до переноса: оборвись питание в середине DirMove, папка может
	; оказаться уже переименованной, и без метки её потом никто не найдёт.
	; Вместе с путём запоминаем, откуда её взяли: после выноса определить это
	; заново невозможно, папки data на месте уже нет.
	IniWrite($gc_sIniFile, "State", "BackupPath", $sBackup)
	IniWrite($gc_sIniFile, "State", "DataPath", $g_sDataPath)

	; Переименование в пределах тома: 9,6 ГБ уезжают мгновенно, копирования нет
	If Not DirMove($g_sDataPath, $sBackup, $FC_OVERWRITE) Then
		IniDelete($gc_sIniFile, "State", "BackupPath")
		IniDelete($gc_sIniFile, "State", "DataPath")
		Return SetError(1, 0, "Целевой путь: " & $sBackup)
	EndIf

	Return $sBackup
EndFunc   ;==>_BackupUserData


Func _RestoreUserData($sBackup)
	If $sBackup = "" Or Not FileExists($sBackup) Then Return True

	DirCreate($g_sTargetPath)
	If Not DirMove($sBackup, $g_sDataPath, $FC_OVERWRITE) Then Return False

	IniDelete($gc_sIniFile, "State", "BackupPath")
	IniDelete($gc_sIniFile, "State", "DataPath")
	Return True
EndFunc   ;==>_RestoreUserData


; Разбирается с последствиями прерванного прогона. Вызывается из _LoadConfig
; до _ApplyPaths: если папку data уже вынесли, _DetectDataPath не найдёт её
; и решит, что данные лежат в профиле - тогда возврат утащил бы портативные
; настройки в %APPDATA%. Поэтому и целевой путь, и место данных берём из ini.
Func _RecoverInterrupted()
	_RecoverRenamed()

	Local $sBackup = IniRead($gc_sIniFile, "State", "BackupPath", "")
	Local $sDataPath = IniRead($gc_sIniFile, "State", "DataPath", "")
	If $sBackup = "" Then Return

	If Not FileExists($sBackup) Then ; папку уже вернули или убрали руками
		IniDelete($gc_sIniFile, "State", "BackupPath")
		IniDelete($gc_sIniFile, "State", "DataPath")
		Return
	EndIf

	If $sDataPath = "" Then Return ; куда возвращать - неизвестно, трогать не станем
	_Util_Log("Найден бэкап прерванного прогона: '" & $sBackup & "' → '" & $sDataPath & "'")

	If FileExists($sDataPath) Then
		; Data уже на месте: вынесенная копия осталась от прерванного прогона
		Local $iAnswer = MsgBox(BitOR($MB_ICONWARNING, $MB_YESNO), $gc_sTitle, _
				"После прерванного обновления осталась папка:" & @CR & $sBackup & @CR & @CR & _
				"Папка данных при этом на месте. Удалить оставшуюся копию в корзину?")
		If $iAnswer = $IDYES And FileRecycle($sBackup) Then
			IniDelete($gc_sIniFile, "State", "BackupPath")
			IniDelete($gc_sIniFile, "State", "DataPath")
		EndIf
		Return
	EndIf

	DirCreate(_Util_ParentDir($sDataPath))
	If DirMove($sBackup, $sDataPath, $FC_OVERWRITE) Then
		_Util_Log("Папка данных возвращена на место")
		IniDelete($gc_sIniFile, "State", "BackupPath")
		IniDelete($gc_sIniFile, "State", "DataPath")
	Else
		_Util_Log("ОШИБКА: вернуть папку данных не удалось, метка в ini сохранена")
	EndIf
EndFunc   ;==>_RecoverInterrupted


; Старая версия успела переименоваться, но в корзину не уехала: возвращаем имя,
; иначе VS Code выглядит пропавшим, а лаунчер разводит руками.
Func _RecoverRenamed()
	Local $sRenamed = IniRead($gc_sIniFile, "State", "RenamedPath", "")
	Local $sTarget = IniRead($gc_sIniFile, "State", "RenamedFrom", "")
	If $sRenamed = "" Or $sTarget = "" Then Return

	If FileExists($sRenamed) And Not FileExists($sTarget) Then
		_Util_Log("Возврат переименованной папки: '" & $sRenamed & "' → '" & $sTarget & "'")
		DirMove($sRenamed, $sTarget, $FC_OVERWRITE)
	EndIf

	IniDelete($gc_sIniFile, "State", "RenamedPath")
	IniDelete($gc_sIniFile, "State", "RenamedFrom")
EndFunc   ;==>_RecoverRenamed


; Переименовывает каталог VS Code с версией и отправляет в корзину.
; Обе операции возвращают 0 без @error, поэтому проверяем возврат. Если корзина
; недоступна (съёмный диск, отключённая корзина), папку возвращаем под старым
; именем: иначе рабочий VS Code остался бы лежать под чужим названием.
Func _RemoveOldVersion()
	; версия могла не прочитаться - тогда метим папку датой, но не пустотой
	Local $sMark = ($g_sVerCur = "") ? @MDAY & "." & @MON & "." & StringRight(@YEAR, 2) : $g_sVerCur
	Local $sRenamed = $g_sTargetPath & " " & $sMark
	If FileExists($sRenamed) Then FileRecycle($sRenamed)
	If FileExists($sRenamed) Then $sRenamed &= " " & @HOUR & @MIN ; освободить имя не вышло

	; Метка на случай обрыва между переименованием и корзиной
	IniWrite($gc_sIniFile, "State", "RenamedPath", $sRenamed)
	IniWrite($gc_sIniFile, "State", "RenamedFrom", $g_sTargetPath)

	If Not DirMove($g_sTargetPath, $sRenamed, $FC_OVERWRITE) Then
		IniDelete($gc_sIniFile, "State", "RenamedPath")
		IniDelete($gc_sIniFile, "State", "RenamedFrom")
		Return False
	EndIf

	If Not FileRecycle($sRenamed) Then
		DirMove($sRenamed, $g_sTargetPath, $FC_OVERWRITE) ; откат: имя возвращаем на место
		IniDelete($gc_sIniFile, "State", "RenamedPath")
		IniDelete($gc_sIniFile, "State", "RenamedFrom")
		Return False
	EndIf

	IniDelete($gc_sIniFile, "State", "RenamedPath")
	IniDelete($gc_sIniFile, "State", "RenamedFrom")
	Return True
EndFunc   ;==>_RemoveOldVersion






; Запускает VS Code, пробрасывая аргументы командной строки лаунчера.
Func _LaunchVSCode()
	If Not FileExists($g_sCodeExe) Then
		_Util_Log("ОШИБКА: запускать нечего, нет '" & $g_sCodeExe & "'")
		MsgBox($MB_ICONERROR, $gc_sTitle, "Не найден файл" & @CR & $g_sCodeExe)
		Exit 1
	EndIf

	; Если лаунчер запустили из терминала самого VS Code, в окружении висит
	; ELECTRON_RUN_AS_NODE=1 - с ней Code.exe стартует как Node и падает
	EnvSet("ELECTRON_RUN_AS_NODE")

	Local $sCmd = '"' & $g_sCodeExe & '"'
	If $g_sPassArgs <> "" Then $sCmd &= " " & $g_sPassArgs

	Local $iPid = Run($sCmd, $g_sTargetPath)
	If @error Or $iPid = 0 Then
		_Util_Log("ОШИБКА: не удалось запустить '" & $g_sCodeExe & "'")
		MsgBox($MB_ICONERROR, $gc_sTitle, "Не удалось запустить" & @CR & $g_sCodeExe)
		Exit 1
	EndIf
EndFunc   ;==>_LaunchVSCode


; ============================================================
; Разбор командной строки
; ============================================================

; Свои ключи забирает себе, всё остальное уходит в Code.exe как есть.
; Строку собираем из $CmdLine, а не из $CmdLineRaw: при запуске через AutoIt3.exe
; в Raw первым идёт путь к самому скрипту и он уехал бы в аргументы редактора.
Func _ParseCmdLine()
	Local $sArgs = ""

	For $i = 1 To $CmdLine[0]
		Switch StringLower($CmdLine[$i])
			Case "/silent", "-silent", "--silent"
				$g_bSilent = True
			Case Else
				; кавычки снимаются при разборе, возвращаем их путям с пробелами
				$sArgs &= (StringInStr($CmdLine[$i], " ") ? '"' & $CmdLine[$i] & '"' : $CmdLine[$i]) & " "
		EndSwitch
	Next

	$g_sPassArgs = StringStripWS($sArgs, 3)
EndFunc   ;==>_ParseCmdLine


; ============================================================
; Тёмная тема: контролы
; ============================================================

; DWM красит только заголовок, клиентскую область закрашиваем сами.
Func _GUISetDarkTitleBar($hWnd)
	Local $aRet = DllCall("dwmapi.dll", "long", "DwmSetWindowAttribute", _
			"hwnd", $hWnd, _
			"dword", $gc_iDwmDarkMode, _
			"dword*", 1, _ ; BOOL: 1 = тёмный
			"dword", 4)    ; sizeof(BOOL)
	If @error Or $aRet[0] Then Return SetError(1, 0, False)
	Return True
EndFunc   ;==>_GUISetDarkTitleBar


; Выстраивает несколько меток в одну строку встык: ширина каждой берётся у GDI
; по её собственному шрифту, поэтому пробелы внутри текста выглядят как обычные.
; Аргументы после высоты идут парами: ControlID, его текст.
Func _LayoutRow($iLeft, $iTop, $iHeight, $iCtrl1 = 0, $sText1 = "", $iCtrl2 = 0, $sText2 = "", $iCtrl3 = 0, $sText3 = "")
	Local $aCtrl[3] = [$iCtrl1, $iCtrl2, $iCtrl3]
	Local $aText[3] = [$sText1, $sText2, $sText3]
	Local $iX = $iLeft

	For $i = 0 To 2
		If $aCtrl[$i] = 0 Then ExitLoop
		Local $iWidth = _TextWidth($aCtrl[$i], $aText[$i])
		GUICtrlSetPos($aCtrl[$i], $iX, $iTop, $iWidth + 2, $iHeight)
		$iX += $iWidth
	Next
EndFunc   ;==>_LayoutRow


; Ширина строки в пикселях для шрифта, назначенного контролу
Func _TextWidth($iCtrl, $sText)
	Local $hCtrl = GUICtrlGetHandle($iCtrl)
	Local $hDC = _WinAPI_GetDC($hCtrl)
	Local $hOldFont = _WinAPI_SelectObject($hDC, _SendMessage($hCtrl, $WM_GETFONT))

	Local $tSize = _WinAPI_GetTextExtentPoint32($hDC, $sText)

	_WinAPI_SelectObject($hDC, $hOldFont)
	_WinAPI_ReleaseDC($hCtrl, $hDC)
	Return DllStructGetData($tSize, "X")
EndFunc   ;==>_TextWidth


; Задаёт размер клиентской области: WinMove работает с внешними размерами,
; а рамка и заголовок зависят от темы и масштаба, поэтому считаем разницу на месте.
Func _ResizeClient($hWnd, $iWidth, $iHeight)
	Local $aWin = WinGetPos($hWnd)
	Local $aClient = WinGetClientSize($hWnd)
	If Not IsArray($aWin) Or Not IsArray($aClient) Then Return

	WinMove($hWnd, "", Default, Default, _
			$iWidth + ($aWin[2] - $aClient[0]), $iHeight + ($aWin[3] - $aClient[1]))
EndFunc   ;==>_ResizeClient


Func _DarkLabel($sText, $iLeft, $iTop, $iWidth, $iHeight, $iColor, $iBkColor = -1, $iFontSize = $gc_nFontBody, $iWeight = 400, $iStyle = $SS_LEFTNOWORDWRAP)
	Local $iCtrl = GUICtrlCreateLabel($sText, $iLeft, $iTop, $iWidth, $iHeight, $iStyle)
	GUICtrlSetColor($iCtrl, $iColor)
	GUICtrlSetBkColor($iCtrl, ($iBkColor = -1) ? $GUI_BKCOLOR_TRANSPARENT : $iBkColor)
	If $iFontSize <> $gc_nFontBody Or $iWeight <> 400 Then GUICtrlSetFont($iCtrl, $iFontSize, $iWeight, 0, "Segoe UI")
	Return $iCtrl
EndFunc   ;==>_DarkLabel


; Штатная кнопка Win32 тёмной не делается, поэтому кнопка - это Label с $SS_NOTIFY
; (без него клики не приходят) и ручной подсветкой в _UpdateHover.
Func _DarkButton($sText, $iLeft, $iTop, $bAccent = False)
	Local $iCtrl = GUICtrlCreateLabel($sText, $iLeft, $iTop, $gc_iBtnMinWidth, $gc_iBtnHeight, _
			BitOR($SS_CENTER, $SS_CENTERIMAGE, $SS_NOTIFY))
	GUICtrlSetColor($iCtrl, $bAccent ? 0xFFFFFF : $gc_iClrText)
	GUICtrlSetBkColor($iCtrl, $bAccent ? $gc_iClrAccent : $gc_iClrBtn)
	GUICtrlSetFont($iCtrl, $gc_nFontBody, $bAccent ? 600 : 400, 0, "Segoe UI")
	GUICtrlSetCursor($iCtrl, 0) ; рука вместо стрелки

	Local $iIndex = UBound($g_aHotBtn)
	ReDim $g_aHotBtn[$iIndex + 1][4]
	$g_aHotBtn[$iIndex][0] = $iCtrl
	$g_aHotBtn[$iIndex][1] = $bAccent ? $gc_iClrAccent : $gc_iClrBtn
	$g_aHotBtn[$iIndex][2] = $bAccent ? $gc_iClrAccentHot : $gc_iClrBtnHot
	$g_aHotBtn[$iIndex][3] = True

	_FitButton($iCtrl, $iLeft, $iTop)
	Return $iCtrl
EndFunc   ;==>_DarkButton


; Ширина кнопки - по её надписи, но не меньше стандартной. Label под текст не растёт,
; поэтому длинные надписи иначе обрезаются.
Func _FitButton($iCtrl, $iLeft, $iTop)
	Local $iWidth = _TextWidth($iCtrl, GUICtrlRead($iCtrl)) + 2 * $gc_iBtnPadX
	If $iWidth < $gc_iBtnMinWidth Then $iWidth = $gc_iBtnMinWidth

	GUICtrlSetPos($iCtrl, $iLeft, $iTop, $iWidth, $gc_iBtnHeight)
	Return $iWidth
EndFunc   ;==>_FitButton


; Расставляет кнопки в ряд справа налево от $iRight с постоянным зазором.
; Первой передаётся главная кнопка - она встаёт крайней справа.
Func _PlaceButtons($iRight, $iTop, $iBtn1, $iBtn2 = 0)
	Local $aBtn[2] = [$iBtn1, $iBtn2]

	Local $iWidth = 0
	For $i = 0 To 1
		If $aBtn[$i] = 0 Then ExitLoop
		Local $iOwn = _FitButton($aBtn[$i], 0, $iTop) ; ширину узнаём по надписи
		If $iOwn > $iWidth Then $iWidth = $iOwn
	Next

	Local $iX = $iRight
	For $i = 0 To 1
		If $aBtn[$i] = 0 Then ExitLoop
		$iX -= $iWidth
		GUICtrlSetPos($aBtn[$i], $iX, $iTop, $iWidth, $gc_iBtnHeight)
		$iX -= $gc_iBtnGap
	Next
EndFunc   ;==>_PlaceButtons


; Подсветка кнопки под курсором. Вызывается из всех циклов ожидания -
; в OnEventMode это единственное место, где можно отследить наведение без subclassing.
; Перекрашиваем только на смене контрола под курсором: во время загрузки эта
; функция дёргается восемь раз в секунду, и перекраска вслепую заставляла
; кнопки перерисовываться на каждом тике.
; $bReset - забыть, что было под курсором: набор кнопок сменился и старое
; значение больше ничего не значит.
Func _UpdateHover($hWnd, $bReset = False)
	Local Static $iPrev = -1
	If $bReset Then $iPrev = -1
	If $hWnd = 0 Then Return

	Local $aInfo = GUIGetCursorInfo($hWnd)
	Local $iUnder = (IsArray($aInfo) ? $aInfo[4] : 0)
	If $iUnder = $iPrev Then Return
	$iPrev = $iUnder

	For $i = 0 To UBound($g_aHotBtn) - 1
		If Not $g_aHotBtn[$i][3] Then ContinueLoop
		GUICtrlSetBkColor($g_aHotBtn[$i][0], ($g_aHotBtn[$i][0] = $iUnder) ? $g_aHotBtn[$i][2] : $g_aHotBtn[$i][1])
	Next
EndFunc   ;==>_UpdateHover


Func _SetButtonEnabled($iCtrl, $bEnabled)
	For $i = 0 To UBound($g_aHotBtn) - 1
		If $g_aHotBtn[$i][0] <> $iCtrl Then ContinueLoop
		$g_aHotBtn[$i][3] = $bEnabled
		GUICtrlSetBkColor($iCtrl, $bEnabled ? $g_aHotBtn[$i][1] : $gc_iClrBtnDis)
		GUICtrlSetColor($iCtrl, $bEnabled ? (($g_aHotBtn[$i][1] = $gc_iClrAccent) ? 0xFFFFFF : $gc_iClrText) : $gc_iClrBtnDisText)
		GUICtrlSetCursor($iCtrl, $bEnabled ? 0 : 2)
		Return
	Next
EndFunc   ;==>_SetButtonEnabled


; Три раскладки нижних кнопок: во время работы видна только 'Отмена',
; при ошибке добавляется 'Повторить', после успеха остаётся 'Закрыть'.
Func _LayoutButtons($sMode)
	_UpdateHover(0, True) ; кнопки переставляются, прежняя подсветка не в счёт

	Switch $sMode
		Case "work"
			GUICtrlSetState($g_iBtnMain, $GUI_HIDE)
			GUICtrlSetState($g_iBtnAlt, $GUI_SHOW)
			GUICtrlSetData($g_iBtnAlt, "Отмена")
			_PlaceButtons($gc_iBtnRight, $g_iButtonTop, $g_iBtnAlt)
			_SetButtonEnabled($g_iBtnAlt, True)

		Case "error"
			GUICtrlSetState($g_iBtnMain, $GUI_SHOW)
			GUICtrlSetState($g_iBtnAlt, $GUI_SHOW)
			GUICtrlSetData($g_iBtnMain, "Повторить")
			GUICtrlSetData($g_iBtnAlt, "Отмена") ; отказ от повтора: редактор запустится как есть
			_PlaceButtons($gc_iBtnRight, $g_iButtonTop, $g_iBtnMain, $g_iBtnAlt)
			_SetButtonEnabled($g_iBtnMain, True)
			_SetButtonEnabled($g_iBtnAlt, True)

		Case "done"
			GUICtrlSetState($g_iBtnMain, $GUI_HIDE)
			GUICtrlSetData($g_iBtnAlt, "Закрыть")
			_PlaceButtons($gc_iBtnRight, $g_iButtonTop, $g_iBtnAlt)
			_SetButtonEnabled($g_iBtnAlt, True)
	EndSwitch
EndFunc   ;==>_LayoutButtons


Func _IsButtonEnabled($iCtrl)
	For $i = 0 To UBound($g_aHotBtn) - 1
		If $g_aHotBtn[$i][0] = $iCtrl Then Return $g_aHotBtn[$i][3]
	Next
	Return False
EndFunc   ;==>_IsButtonEnabled


; ============================================================
; Отрисовка состояния
; ============================================================

Func _SplashSetState($sText, $sSub, $iColor = $gc_iClrText)
	GUICtrlSetData($g_iSplashText, $sText)
	GUICtrlSetColor($g_iSplashText, $iColor)
	GUICtrlSetData($g_iSplashSub, $sSub)
	GUICtrlSetPos($g_iSplashBar, $gc_iPad, $gc_iSplashActionTop + 13, $gc_iSplashWidth - 2 * $gc_iPad, 6)
EndFunc   ;==>_SplashSetState


; Бегунок неопределённого прогресса: ползёт слева направо, пока идёт запрос к API.
Func _SplashPulse()
	Local Static $iPos = 0
	$iPos = Mod($iPos + 6, $gc_iSplashWidth - 2 * $gc_iPad + 100)
	Local $iTrack = $gc_iSplashWidth - 2 * $gc_iPad
	Local $iLeft = $gc_iPad + (($iPos > 100) ? $iPos - 100 : 0)
	Local $iWidth = ($iPos < 100) ? $iPos : (($iPos > $iTrack) ? $iTrack + 100 - $iPos : 100)
	GUICtrlSetPos($g_iSplashBar, $iLeft, $gc_iSplashActionTop + 13, $iWidth, 6)
EndFunc   ;==>_SplashPulse


Func _CloseSplash()
	If $g_hSplash = 0 Then Return
	GUIDelete($g_hSplash)
	$g_hSplash = 0
	$g_iSplashBtnUpdate = 0
	$g_iSplashBtnRun = 0
	ReDim $g_aHotBtn[0][4]
	_UpdateHover(0, True)
EndFunc   ;==>_CloseSplash


; Состояния шага: wait, run, done, err.
Func _SetStep($iStep, $sState, $sSub = "")
	Local $sMark = $gc_sMarkWait, $iMarkColor = $gc_iClrWait, $iTextColor = $gc_iClrWait

	Switch $sState
		Case "run"
			$sMark = $gc_sMarkRun
			$iMarkColor = $gc_iClrRun
			$iTextColor = $gc_iClrText
		Case "done"
			$sMark = $gc_sMarkDone
			$iMarkColor = $gc_iClrOk
			$iTextColor = $gc_iClrText
		Case "err"
			$sMark = $gc_sMarkErr
			$iMarkColor = $gc_iClrErr
			$iTextColor = $gc_iClrErr
	EndSwitch

	GUICtrlSetData($g_aMarker[$iStep], $sMark)
	GUICtrlSetColor($g_aMarker[$iStep], $iMarkColor)
	GUICtrlSetColor($g_aStepLabel[$iStep], $iTextColor)
	GUICtrlSetColor($g_aStepSub[$iStep], ($sState = "err") ? $gc_iClrErr : $gc_iClrDim)
	If $sSub <> "" Or $sState <> "run" Then GUICtrlSetData($g_aStepSub[$iStep], $sSub)

	If $sState = "done" Then _SetProgressStep($iStep + 1, 0)
EndFunc   ;==>_SetStep


Func _ResetSteps()
	For $i = 0 To UBound($g_aStepTitle) - 1
		_SetStep($i, "wait")
	Next
	_SetStep(0, "done", _ReleaseLine())
	GUICtrlSetBkColor($g_iBar, $gc_iClrBar)
	_LayoutButtons("work")
EndFunc   ;==>_ResetSteps


; $sInfo - подробности хода работы, идут в правой части той же строки серым
Func _SetStatus($sText, $bError = False, $sInfo = "")
	; без подробностей строка состояния занимает всю ширину, иначе её обрезает
	GUICtrlSetPos($g_iStatus, $gc_iBarLeft, $g_iBarTop + 16, ($sInfo = "") ? $gc_iBarWidth : 200, 20)
	GUICtrlSetData($g_iStatus, $sText)
	GUICtrlSetColor($g_iStatus, $bError ? $gc_iClrErr : $gc_iClrText)
	GUICtrlSetData($g_iStatusInfo, $sInfo)
EndFunc   ;==>_SetStatus


Func _SetProgress($nPercent)
	Local $iWidth = Int($gc_iBarWidth * $nPercent / 100)
	If $iWidth < 0 Then $iWidth = 0
	If $iWidth > $gc_iBarWidth Then $iWidth = $gc_iBarWidth
	GUICtrlSetPos($g_iBar, $gc_iBarLeft, $g_iBarTop, $iWidth, $gc_iBarHeight)
EndFunc   ;==>_SetProgress


; Общий прогресс = сумма весов пройденных шагов + доля текущего.
Func _SetProgressStep($iStep, $nFraction)
	Local $nBase = 0
	For $i = 0 To $iStep - 1
		If $i > UBound($g_aStepWeight) - 1 Then ExitLoop
		$nBase += $g_aStepWeight[$i]
	Next

	Local $nOwn = ($iStep <= UBound($g_aStepWeight) - 1) ? $g_aStepWeight[$iStep] * $nFraction : 0
	_SetProgress($nBase + $nOwn)
EndFunc   ;==>_SetProgressStep


; ============================================================
; Утилиты
; ============================================================

; Подстрочник шага проверки: новая версия и когда её выпустили
Func _ReleaseLine()
	Local $sDate = _FormatReleaseDate($g_iVerStamp)
	Return ($sDate = "") ? $g_sVerNew : $g_sVerNew & " от " & $sDate
EndFunc   ;==>_ReleaseLine


; Unix-время в миллисекундах - в местную дату вида 19.08.26. Сервер отдаёт UTC,
; а у пояса вроде UTC+6 это уже следующие сутки, поэтому смещение учитываем.
Func _FormatReleaseDate($iUnixMs)
	If $iUnixMs <= 0 Then Return ""

	Local $sDate = _DateAdd("s", Int($iUnixMs / 1000), "1970/01/01 00:00:00")

	Local $aTz = _Date_Time_GetTimeZoneInformation()
	If Not @error And IsArray($aTz) Then
		Local $iBias = $aTz[1] + (($aTz[0] = 2) ? $aTz[7] : 0) ; 2 - действует летнее время
		$sDate = _DateAdd("n", -$iBias, $sDate)
	EndIf

	Local $aParts = StringRegExp($sDate, '^(\d{4})/(\d{2})/(\d{2})', 1)
	If @error Then Return ""
	Return $aParts[2] & "." & $aParts[1] & "." & StringRight($aParts[0], 2) ; год везде двузначный
EndFunc   ;==>_FormatReleaseDate


; Сравнивает '1.134.0' и '1.135.0' по числам: 1 - первая новее, 0 - равны, -1 - старее.
Func _CompareVersions($sLeft, $sRight)
	Local $aLeft = StringSplit($sLeft, ".", 2)
	Local $aRight = StringSplit($sRight, ".", 2)
	Local $iMax = (UBound($aLeft) > UBound($aRight)) ? UBound($aLeft) : UBound($aRight)

	For $i = 0 To $iMax - 1
		Local $iL = ($i < UBound($aLeft)) ? Int($aLeft[$i]) : 0
		Local $iR = ($i < UBound($aRight)) ? Int($aRight[$i]) : 0
		If $iL > $iR Then Return 1
		If $iL < $iR Then Return -1
	Next

	Return 0
EndFunc   ;==>_CompareVersions


Func _FormatSize($iBytes)
	If $iBytes >= 1073741824 Then Return _Decimal($iBytes / 1073741824, 1) & " ГБ"
	If $iBytes >= 1048576 Then Return _Decimal($iBytes / 1048576, 1) & " МБ"
	If $iBytes >= 1024 Then Return _Decimal($iBytes / 1024, 0) & " КБ"
	Return $iBytes & " Б"
EndFunc   ;==>_FormatSize


; $bRoundUp - для оценки остатка: 'осталось 0 с' выглядит странно, поэтому вверх
; '84,6 из 319,3 МБ': единицу измерения повторять у обоих чисел незачем
Func _FormatSizePair($iDone, $iTotal)
	Local $sTotal = _FormatSize($iTotal)
	Local $aDone = StringSplit(_FormatSize($iDone), " ", 2)
	Local $aTotal = StringSplit($sTotal, " ", 2)

	If UBound($aDone) = 2 And UBound($aTotal) = 2 And $aDone[1] = $aTotal[1] Then Return $aDone[0] & " из " & $sTotal
	Return _FormatSize($iDone) & " из " & $sTotal
EndFunc   ;==>_FormatSizePair


Func _FormatTime($nSeconds, $bRoundUp = True)
	If $nSeconds >= 60 Then Return Int($nSeconds / 60) & " мин " & Int(Mod($nSeconds, 60)) & " сек"
	Return Int($nSeconds) + ($bRoundUp ? 1 : 0) & " сек"
EndFunc   ;==>_FormatTime


; Разделитель дробной части - запятая, StringFormat в любой локали даёт точку
Func _Decimal($nValue, $iDigits)
	Return StringReplace(StringFormat("%." & $iDigits & "f", $nValue), ".", ",")
EndFunc   ;==>_Decimal


; На каком проценте оборвалась загрузка - подстрочник шага при ошибке
Func _DownloadedPercent()
	If $g_iZipSize <= 0 Then Return ""

	Local $iDone = _Util_FileSizeLive($g_sZipFile)
	If $iDone <= 0 Then Return ""
	Return "прервано на " & Int($iDone / $g_iZipSize * 100) & " %"
EndFunc   ;==>_DownloadedPercent


; Сколько уже лежит в недокачанном файле - показываем в вопросе про обновление
Func _DownloadedPart()
	Local $iSize = _Util_FileSizeLive($g_sZipFile)
	If $iSize <= 0 Then Return ""
	Return _FormatSize($iSize)
EndFunc   ;==>_DownloadedPart


