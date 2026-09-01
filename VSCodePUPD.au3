#pragma compile(Out, #Build\VSCodePUPD.exe)
#pragma compile(Icon, Assets\Icon.ico)
#pragma compile(ProductName, VSCodePUPD)
#pragma compile(FileDescription, Launcher and updater for portable VS Code)
#pragma compile(FileVersion, 1.0.2.0)
; Разрядность закреплена: _ProcessCwd читает PEB чужого процесса по смещениям x64,
; из 32-битной сборки они указывают не туда
#pragma compile(x64, true)

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
#include "Include/Common.au3"
#include "Include/Controls.au3"
#include "Include/Downloader.au3"
#include "Include/StartWindow.au3"
#include "Include/UpdateWindow.au3"
#include "Include/Util.au3"

Opt("GUIOnEventMode", 1)
Opt("MustDeclareVars", 1)

; ============================================================
; Константы
; ============================================================

; Строки окна настройки: участвуют в расчёте ширины окна, поэтому нужны заранее
Global Const $gc_sDataPrefix = "Папка пользователя: "

; Запас поверх размера архива: распакованная сборка примерно вдвое больше,
; и обе версии какое-то время лежат на диске одновременно
Global Const $gc_nSpaceFactor = 3.5

Global Const $gc_iCheckTimeout = 4000 ; мс: дольше ждать нельзя, лаунчер стоит перед запуском редактора

; ============================================================
; Глобальные переменные
; ============================================================

; GUI: окно первого запуска
Global $g_hSetup = 0, $g_iSetupInput, $g_iSetupData
Global $g_iSetupBrowse = 0, $g_iSetupSave = 0, $g_iSetupCancel = 0

; ============================================================
; Стартовая последовательность
; ============================================================

_ParseCmdLine()
; Запущенный из терминала VS Code лаунчер получает рабочий каталог внутри
; обновляемой папки и держал бы её сам - уводим себя к своему exe
FileChangeDir(@ScriptDir)
_Util_LogStart($gc_sLogFile, $gc_sTitle & " запуск" & ($g_bSilent ? " (/silent)" : ""))
_LoadConfig() ; внутри же разбирается с последствиями прерванного прогона
_BuildSteps()

$g_sVerCur = _GetVSCodeVers()
_Util_Log("Установлено: " & (($g_sVerCur = "") ? "версия не читается" : $g_sVerCur) & " в '" & $g_sTargetPath & "'")

If Not $g_bSilent Then _RunLauncherFlow()

_LaunchVSCode()
Exit


; ============================================================
; Сценарий лаунчера
; ============================================================

; Проверка обновления в маленьком окне, при наличии - вопрос и переход в основное окно.
Func _RunLauncherFlow()
	_StartGUI()

	Local $aUpd = _Net_CheckUpdate($gc_sUpdateApi, $gc_iCheckTimeout, "_StartPulse")
	Local $iErr = @error
	If $iErr Then
		; ссылка на чужой хост - это не сбой сети, о таком надо сказать прямо
		If $iErr = 4 Then Return _StartDone("ОТКАЗ: сервер вернул ссылку на неизвестный хост", _
				"Ссылка не от Microsoft", "Обновление отменено, запуск " & $g_sVerCur & "...")

		Return _StartDone("Сервер обновлений недоступен (код " & $iErr & ")", _
				"Сервер обновлений недоступен", "Запуск текущей версии " & $g_sVerCur & "...", 900)
	EndIf

	$g_sVerNew = $aUpd[0]
	$g_sUrl = $aUpd[1]
	$g_sHash = $aUpd[2]
	$g_iVerStamp = $aUpd[3]
	_Util_Log("Сервер предлагает " & $g_sVerNew)

	If _CompareVersions($g_sVerNew, $g_sVerCur) <= 0 Then Return _StartDone("", _
			"Установлена последняя версия " & $g_sVerCur, "Запуск VS Code...", 700, $gc_iClrOk)

	; Свой же процесс удержит папку от удаления, если программа лежит внутри неё
	If _Util_IsInsidePath(@ScriptDir, $g_sTargetPath) Then Return _StartDone( _
			"ОТКАЗ: программа лежит внутри обновляемой папки", _
			"Обновление невозможно", "VSCodePUPD лежит внутри папки VS Code")

	$g_sZipFile = $g_sWorkDir & "\" & _Util_FileName($g_sUrl)
	$g_iZipSize = _Net_GetRemoteSize($g_sUrl, 5000, "_StartPulse")

	; Места должно хватить и на архив, и на обе версии рядом
	Local $sSpace = _CheckFreeSpace()
	If $sSpace <> "" Then Return _StartDone("ОТКАЗ: " & $sSpace, _
			"Не хватает места на диске", $sSpace, 3000)

	If Not _AskAndFreeFolder() Then Return _StartClose()

	; Второе окно поднимаем до того, как убрать первое: иначе между ними
	; проскакивает голый рабочий стол
	_MainGUI()
	_StartClose()
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
	Local $sBusy = _FolderNames(_FolderHolders($g_sTargetPath))
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

	; --- Проверка: своим пунктом не идёт, спрос с распаковки ---
	Local $sVerAfter = _GetVSCodeVers()
	If $sVerAfter = "" Or _CompareVersions($sVerAfter, $g_sVerCur) <= 0 Then
		_Util_Log("ОШИБКА: после распаковки версия '" & $sVerAfter & "' не новее '" & $g_sVerCur & "'")
		Return _FailStep($g_iStepUnpack, "После распаковки версия не изменилась: " & $sVerAfter, _
				"архив мог быть собран не для этой платформы")
	EndIf

	FileRecycle($g_sZipFile)
	IniDelete($gc_sIniFile, "State")
	_SetProgress(100)
	_SetStatus("Обновлено до " & $sVerAfter & ", запуск VS Code...")
	_LayoutButtons("done")
	$g_sVerCur = $sVerAfter
	_Util_Log("ГОТОВО: обновлено до " & $sVerAfter)

	_Wait(1200, $g_hMain)
	Return False
EndFunc   ;==>_RunUpdateOnce


; ============================================================
; Окно держателей папки
; ============================================================

; ============================================================
; Занятость папки
; ============================================================

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

	_HotBtnForget($g_iSetupBrowse, $g_iSetupSave, $g_iSetupCancel)
	GUIDelete($g_hSetup)

	$g_hSetup = 0
	$g_iSetupBrowse = 0
	$g_iSetupSave = 0
	$g_iSetupCancel = 0
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

		; Причина почти всегда одна - папку кто-то держит. Имя виновника полезнее
		; целевого пути: по нему понятно, что закрывать перед повтором.
		Local $sBusy = _FolderNames(_FolderHolders($g_sDataPath))
		Return SetError(1, 0, ($sBusy = "") ? "целевой путь: " & $sBackup : "держат папку: " & $sBusy)
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

; ============================================================
; Отрисовка состояния
; ============================================================

; ============================================================
; Утилиты
; ============================================================

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


