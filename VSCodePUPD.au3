#pragma compile(Out, #Build\VSCodePUPD.exe)
#pragma compile(Icon, Assets\Icons\Icon.ico)
#pragma compile(ProductName, VSCodePUPD)
#pragma compile(FileDescription, Updater for portable VS Code)
#pragma compile(FileVersion, 1.0.3.0)
#pragma compile(x64, true)

#NoTrayIcon

#include <GUIConstantsEx.au3>
#include <MsgBoxConstants.au3>
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

; Префикс строки о папке данных: входит в расчёт ширины окна первого запуска
Global Const $gc_sDataPrefix = "Папка пользователя: "

; Запас места поверх размера архива: распакованная сборка примерно вдвое больше,
; и обе версии какое-то время лежат на диске одновременно
Global Const $gc_nSpaceFactor = 3.5

Global Const $gc_iCheckTimeout = 4000 ; мс: лаунчер стоит перед запуском редактора

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
; Из терминала VS Code рабочий каталог достаётся внутри обновляемой папки и держал бы её
FileChangeDir(@ScriptDir)
_Util_LogStart($gc_sLogFile, $gc_sTitle & " запуск" & ($g_bSilent ? " (/silent)" : ""))
_LoadConfig()
_BuildSteps()

$g_sVerCur = _GetVSCodeVers()
_Util_Log("Установлено: " & (($g_sVerCur = "") ? "версия не читается" : $g_sVerCur) & " в '" & $g_sTargetPath & "'")

If Not $g_bSilent Then _RunLauncherFlow()

_LaunchVSCode()
Exit


; ============================================================
; Сценарий лаунчера
; ============================================================

; Проверка обновления в первом окне, при согласии - обновление во втором.
Func _RunLauncherFlow()
	_StartGUI()

	Local $aUpd = _Net_CheckUpdate($gc_sUpdateApi, $gc_iCheckTimeout, "_StartPulse")
	Local $iErr = @error
	If $iErr Then
		; чужой хост - не сбой сети, об этом говорим прямо
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
			"У вас установлена последняя версия " & $g_sVerCur, "Запуск VS Code...", 100, $gc_iClrText)

	; Свой же процесс не дал бы удалить папку, в которой лежит программа
	If _Util_IsInsidePath(@ScriptDir, $g_sTargetPath) Then Return _StartDone( _
			"ОТКАЗ: программа лежит внутри обновляемой папки", _
			"Обновление невозможно", "VSCodePUPD лежит внутри папки VS Code")

	$g_sZipFile = $g_sWorkDir & "\" & _Util_FileName($g_sUrl)
	$g_iZipSize = _Net_GetRemoteSize($g_sUrl, 5000, "_StartPulse")

	Local $sSpace = _CheckFreeSpace()
	If $sSpace <> "" Then Return _StartDone("ОТКАЗ: " & $sSpace, _
			"Не хватает места на диске", $sSpace, 3000)

	If Not _AskAndFreeFolder() Then Return _StartClose()

	; Второе окно - до того, как убрать первое: иначе между ними мелькнёт рабочий стол
	_MainGUI()
	_StartClose()
	_RunUpdate()
EndFunc   ;==>_RunLauncherFlow


; Хватит ли места на архив и обе версии VS Code рядом.
; '' - хватает или проверить не удалось, иначе текст для показа.
Func _CheckFreeSpace()
	If $g_iZipSize <= 0 Then Return ""

	Local $nNeed = $g_iZipSize * $gc_nSpaceFactor
	Local $nFree = _Util_FreeSpace($g_sWorkDir)
	If $nFree < 0 Then Return "" ; сетевой путь или том не определился - не мешаем

	If $nFree >= $nNeed Then Return ""
	Return "нужно около " & _FormatSize($nNeed) & ", свободно " & _FormatSize($nFree)
EndFunc   ;==>_CheckFreeSpace


; Обновление в основном окне. Повторы после ошибки - циклом, а не рекурсией: стек не растёт.
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

	; --- Загрузка и сверка суммы: один шаг ---
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
		FileDelete($g_sZipFile) ; битую докачку продолжать нельзя
		Return _FailStep($g_iStepDownload, "Архив повреждён", "SHA-256 не совпал с ответом сервера, файл удалён")
	EndIf
	_SetStep($g_iStepDownload, "done", $g_sDownloadSummary)
	_Util_Log("Архив загружен и проверен: " & $g_sDownloadSummary)

	; За минуты загрузки редактор могли запустить снова. Как и в первом окне,
	; списка процессов мало - точный ответ даёт проба переименованием.
	If FileExists($g_sTargetPath) Then
		Local $aBusy = _FolderHolders($g_sTargetPath)
		If UBound($aBusy) Or Not _FolderIsFree($g_sTargetPath) Then Return _FailStep($g_iStepRemove, _
				"Папка VS Code занята", UBound($aBusy) ? "закройте: " & _FolderNames($aBusy) : "её удерживает программа, которую не видно")
	EndIf

	; Дальше отменять нельзя: папки начинают переезжать
	$g_bCancelLocked = True
	_SetButtonEnabled($g_iBtnAlt, False)

	; --- Вынос папки данных: только если она внутри каталога VS Code ---
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
		; В наполовину распакованный каталог данные не возвращаем: следующая распаковка
		; перемешала бы их с новой сборкой. Их подхватит повтор или следующий запуск по ini.
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

	; --- Проверка версии: своего пункта нет, спрос с распаковки ---
	Local $sVerAfter = _GetVSCodeVers()
	If $sVerAfter = "" Or _CompareVersions($sVerAfter, $g_sVerCur) <= 0 Then
		_Util_Log("ОШИБКА: после распаковки версия '" & $sVerAfter & "' не новее '" & $g_sVerCur & "'")
		Return _FailStep($g_iStepUnpack, "После распаковки версия не изменилась: " & $sVerAfter, _
				"архив мог быть собран не для этой платформы")
	EndIf

	FileRecycle($g_sZipFile)
	IniDelete($gc_sIniFile, "State")
	$g_bCancelLocked = False ; иначе 'Закрыть' не нажимается
	_SetProgress(100)
	_SetStatus("Обновлено до " & $sVerAfter & ", запуск VS Code...")
	_LayoutButtons("done")
	$g_sVerCur = $sVerAfter
	_Util_Log("ГОТОВО: обновлено до " & $sVerAfter)

	_Wait(1200, $g_hMain)
	Return False
EndFunc   ;==>_RunUpdateOnce


; ============================================================
; Настройки и первый запуск
; ============================================================

; Окно первого запуска: путь к VS Code и что программа поняла про папку данных.
; True - настройки сохранены, False - пользователь отказался.
Func _SetupGUI()
	Local Const $iMinWidth = 440 ; уже неудобно вводить путь
	Local $iWidth = 900 ; с запасом: ужмётся после замера строк

	$g_hSetup = GUICreate($gc_sTitle & " - Первый запуск", $iWidth, 600, -1, -1, _
			BitOR($WS_POPUP, $WS_CAPTION, $WS_SYSMENU), $WS_EX_TOPMOST)
	GUISetBkColor($gc_iClrBg, $g_hSetup)
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hSetup)
	_GUISetDarkTitleBar($g_hSetup)

	Local $aLines[0][2] ; [ControlID, текст] - по ним считаем ширину окна
	Local $iY = $gc_iPad

	; --- Что это и зачем ---
	Local $aAbout[3] = [ _
			"Портативный Visual Studio Code из коробки не обновляется автоматически.", _
			"Приходится качать архив и переносить в него пользовательские настройки", _
			"вручную. Теперь VSCodePUPD берёт это на себя."]
	$iY = _SetupBlock($aLines, "VSCodePUPD", $aAbout, $iY)

	; --- Что программа делает с вашими данными ---
	Local $aSafe[3] = [ _
			"Обновление начинается только по вашей команде. Архив скачивается из", _
			"официального источника Microsoft. Настройки и расширения переносятся", _
			"целиком. Старые версии и архивы удаляются только через корзину."]
	$iY = _SetupBlock($aLines, "Насколько это безопасно", $aSafe, $iY + 10) + 18

	; --- Папка VS Code ---
	_SetupAddLine($aLines, _DarkLabel("Папка VS Code", $gc_iPad, $iY, 400, 20, $gc_iClrText), "Папка VS Code")
	$iY += 24

	$g_iSetupInput = GUICtrlCreateInput($g_sTargetPath, $gc_iPad, $iY, 100, $gc_iBtnHeight)
	GUICtrlSetBkColor($g_iSetupInput, 0x2D2D2D)
	GUICtrlSetColor($g_iSetupInput, $gc_iClrText)
	GUICtrlSetFont($g_iSetupInput, $gc_nFontBody, 400, 0, "Segoe UI")
	$g_iSetupBrowse = _DarkButton("Обзор...", $gc_iPad, $iY) ; к правому краю после замера
	Local $iInputTop = $iY
	$iY += $gc_iBtnHeight + 14

	$g_iSetupData = _DarkLabel("", $gc_iPad, $iY, 600, 20, $gc_iClrText)
	$iY += 20 + 16

	$g_iSetupSave = _DarkButton("Применить", $gc_iPad, $iY, True)
	$g_iSetupCancel = _DarkButton("Отмена", $gc_iPad, $iY)

	; Строка о папке данных заполнится позже, но в ширину окна закладывается сейчас
	Local $aData = _DetectDataPath($g_sTargetPath)
	_SetupAddLine($aLines, $g_iSetupData, $gc_sDataPrefix & $aData[0])

	; --- Окно по содержимому: ширина по самой длинной строке, высота по последнему ряду ---
	Local $iTextWidth = $iMinWidth - 2 * $gc_iPad
	For $i = 0 To UBound($aLines) - 1
		Local $iLine = _TextWidth($aLines[$i][0], $aLines[$i][1])
		If $iLine > $iTextWidth Then $iTextWidth = $iLine
	Next

	$iTextWidth += 30 ; воздух справа
	$iWidth = $iTextWidth + 2 * $gc_iPad
	Local $iHeight = $iY + $gc_iBtnHeight + $gc_iPad
	_ResizeClient($g_hSetup, $iWidth, $iHeight)

	For $i = 0 To UBound($aLines) - 1
		Local $aPos = ControlGetPos($g_hSetup, "", $aLines[$i][0])
		GUICtrlSetPos($aLines[$i][0], $gc_iPad, $aPos[1], $iTextWidth, $aPos[3])
	Next

	GUICtrlSetPos($g_iSetupInput, $gc_iPad, $iInputTop, $iTextWidth - $gc_iBtnMinWidth - $gc_iBtnGap, $gc_iBtnHeight)
	GUICtrlSetPos($g_iSetupBrowse, $iWidth - $gc_iPad - $gc_iBtnMinWidth, $iInputTop, $gc_iBtnMinWidth, $gc_iBtnHeight)
	_PlaceButtons($iWidth - $gc_iPad, $iY, $g_iSetupSave, $g_iSetupCancel)

	GUISetOnEvent($GUI_EVENT_CLOSE, "_OnEvent_SetupCancel", $g_hSetup)
	GUICtrlSetOnEvent($g_iSetupBrowse, "_OnEvent_SetupBrowse")
	GUICtrlSetOnEvent($g_iSetupSave, "_OnEvent_SetupSave")
	GUICtrlSetOnEvent($g_iSetupCancel, "_OnEvent_SetupCancel")

	_SetupRefresh()
	GUISetState(@SW_SHOW, $g_hSetup)

	; Вписанный руками путь Input событием не сообщает - следим сами
	Local $sLast = GUICtrlRead($g_iSetupInput)
	$g_iChoice = 0
	While $g_iChoice = 0
		Sleep(30)
		_UpdateHover($g_hSetup)
		Local $sNow = GUICtrlRead($g_iSetupInput)
		If $sNow <> $sLast Then
			$sLast = $sNow
			_SetupRefresh()
		EndIf
	WEnd

	Local $bSaved = ($g_iChoice = 1)
	If $bSaved Then
		$g_sTargetPath = _Util_TrimPath(GUICtrlRead($g_iSetupInput))
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


; Запоминает строку для замера ширины окна
Func _SetupAddLine(ByRef $aLines, $iCtrl, $sText)
	Local $iIndex = UBound($aLines)
	ReDim $aLines[$iIndex + 1][2]
	$aLines[$iIndex][0] = $iCtrl
	$aLines[$iIndex][1] = $sText
EndFunc   ;==>_SetupAddLine


; Строка о папке данных под текущий путь в поле ввода
Func _SetupRefresh()
	Local $sPath = _Util_TrimPath(GUICtrlRead($g_iSetupInput))

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


; Пути из ini рядом с программой. Нет настроек или папка не годится - окно первого запуска.
Func _LoadConfig()
	Local $sSaved = _Util_TrimPath(IniRead($gc_sIniFile, "Paths", "TargetPath", ""))
	$g_sTargetPath = ($sSaved <> "") ? $sSaved : _GuessTargetPath()

	; Прерванный прогон - до _ApplyPaths: вынесенная папка данных сбивает определение их места
	_RecoverInterrupted()

	; Окно показываем и когда папка нашлась сама: человек должен подтвердить, что обновляется
	If $sSaved = "" Or Not _IsVSCodeFolder($g_sTargetPath) Then
		If $g_bSilent Then Return _ApplyPaths() ; без окон: разбираться будет _LaunchVSCode
		If Not _SetupGUI() Then Exit
	EndIf

	_ApplyPaths()
EndFunc   ;==>_LoadConfig


; Производные пути от выбранной папки VS Code
Func _ApplyPaths()
	$g_sCodeExe = $g_sTargetPath & "\Code.exe"
	$g_sWorkDir = IniRead($gc_sIniFile, "Paths", "WorkDir", "")
	If $g_sWorkDir = "" Then $g_sWorkDir = _Util_ParentDir($g_sTargetPath) & "\VSCodeUpdate"

	Local $aData = _DetectDataPath($g_sTargetPath)
	$g_sDataPath = $aData[0]
	$g_bDataInside = ($aData[1] = "inside")
EndFunc   ;==>_ApplyPaths


; Где VS Code держит настройки и расширения: [путь, вид].
;   inside       - внутри каталога VS Code, при обновлении её уносим
;   portable-env - VSCODE_PORTABLE снаружи, обновление её не трогает
;   profile      - %APPDATA%\Code, обновление её не трогает
Func _DetectDataPath($sTarget)
	Local $aResult[2]
	Local $sEnv = EnvGet("VSCODE_PORTABLE")
	Local $bEnv = ($sEnv <> "" And FileExists($sEnv))

	If $bEnv And _Util_IsInsidePath($sEnv, $sTarget) Then
		$aResult[0] = $sEnv
		$aResult[1] = "inside"
		Return $aResult
	EndIf

	; Дальше папка data главнее переменной, хотя сам VS Code решает наоборот: переменная
	; достаётся по наследству от запущенного редактора и может указывать на чужие данные.
	; Поверь мы ей, данные этой сборки уехали бы в корзину вместе со старой версией.
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


; Догадка до первой настройки: папка программы, 'VS Code' в ней, 'VS Code' по соседству
Func _GuessTargetPath()
	Local $aTry[3] = [@ScriptDir, @ScriptDir & "\VS Code", _Util_ParentDir(@ScriptDir) & "\VS Code"]

	For $i = 0 To UBound($aTry) - 1
		If _IsVSCodeFolder($aTry[$i]) Then Return $aTry[$i]
	Next

	Return ""
EndFunc   ;==>_GuessTargetPath


; ============================================================
; Загрузка и распаковка
; ============================================================

; Загрузка с колбэками окна. @error пробрасывается без изменений.
Func _DownloadArchive()
	If Not FileExists($g_sWorkDir) Then DirCreate($g_sWorkDir)
	If Not FileExists($g_sWorkDir) Then Return SetError(4, 0, 0) ; качать некуда

	Local $nSeconds = _Net_Download($g_sUrl, $g_sZipFile, $g_iZipSize, "_OnDownloadProgress", "_IsAborted")
	Local $iErr = @error
	If $iErr Then
		If $iErr <> 2 Then _Util_Log("ОШИБКА загрузки: код " & $iErr & ", curl " & @extended)
		Return SetError($iErr, @extended, 0)
	EndIf

	; размер сервер мог не сообщить - тогда берём фактический
	Local $iSize = ($g_iZipSize > 0) ? $g_iZipSize : _Util_FileSizeLive($g_sZipFile)
	$g_sDownloadSummary = ($nSeconds > 0) _
			? _FormatSize($iSize) & " за " & _FormatTime($nSeconds, False) _
			: _FormatSize($iSize) & ", уже был загружен"
	Return 1
EndFunc   ;==>_DownloadArchive


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


; Колбэки прогресса. Подсветку кнопок держит _IsAborted: модули зовут его на каждом круге.
Func _OnUnpackProgress($iDone, $iExpected)
	_SetProgressStep($g_iStepUnpack, $iDone / $iExpected)
	_SetStatus("Распаковка архива...", False, _FormatSizePair($iDone, $iExpected))
EndFunc   ;==>_OnUnpackProgress


; Сверка - последняя доля шага загрузки ($gc_nHashShare). Блоков сотни, а видно
; только проценты: окно трогаем при их смене, втрое реже.
Func _OnHashProgress($iDone, $iTotal)
	If $iTotal <= 0 Then Return

	Local Static $iShown = -1
	Local $iPercent = Int($iDone / $iTotal * 100)
	If $iPercent = $iShown Then Return
	$iShown = $iPercent

	_SetProgressStep($g_iStepDownload, 1 - $gc_nHashShare + $gc_nHashShare * $iDone / $iTotal)
	_SetStatus("Проверка контрольной суммы...", False, $iPercent & " %")
EndFunc   ;==>_OnHashProgress


Func _IsAborted()
	_UpdateHover($g_hMain)
	Return $g_bCancel
EndFunc   ;==>_IsAborted


; Подстрочник загрузки: сколько скачано, скорость, сколько осталось
Func _OnDownloadProgress($iDone, $nSpeed)
	Local $sText = _FormatSize($iDone)
	If $g_iZipSize > 0 Then
		$sText = _FormatSizePair($iDone, $g_iZipSize)
		_SetProgressStep($g_iStepDownload, $iDone / $g_iZipSize * (1 - $gc_nHashShare))
	EndIf

	If $nSpeed > 1024 Then
		$sText &= $gc_sDot & _FormatSize($nSpeed) & "/с"
		If $g_iZipSize > $iDone Then
			$sText &= $gc_sDot & "осталось " & _FormatTime(($g_iZipSize - $iDone) / $nSpeed)
		EndIf
	EndIf

	_SetStatus("Загрузка архива...", False, $sText)
EndFunc   ;==>_OnDownloadProgress


; ============================================================
; Файловые операции
; ============================================================
; DirMove, FileRecycle и FileDelete при неудаче @error не ставят - проверяем возврат.
; DirMove без $FC_OVERWRITE: с ним в существующую папку источник молча вкладывается внутрь.

; Версия VS Code из файловой версии Code.exe: '1.134.0.0' → '1.134.0', '' - не прочитать.
; Без выхода по ошибке: после удачной распаковки он оставил бы человека без редактора.
Func _GetVSCodeVers()
	Local $sVers = FileGetVersion($g_sCodeExe)
	If @error Or $sVers = "" Then Return ""
	Return StringRegExpReplace($sVers, '\.\d+$', '')
EndFunc   ;==>_GetVSCodeVers


; Выносит папку данных за пределы каталога VS Code. Возвращает путь выноса,
; '' - папки не было, при @error - текст ошибки для показа.
Func _BackupUserData()
	If Not FileExists($g_sDataPath) Then
		; Повтор после сбоя: папку уже вынес прошлый проход, она ждёт по метке в ini.
		; Без этого повтор решил бы, что папки нет, и снял метку в конце.
		Local $sPrev = IniRead($gc_sIniFile, "State", "BackupPath", "")
		If $sPrev <> "" And FileExists($sPrev) And IniRead($gc_sIniFile, "State", "DataPath", "") = $g_sDataPath Then Return $sPrev
		Return ""
	EndIf

	Local $sBackup = _Util_FreeName(_Util_ParentDir($g_sTargetPath) & "\VSCodeUserData " & _DateShort())

	; Метка - до переноса: оборвись он на середине, папку без неё не найти. Место data пишем
	; тоже: после выноса её там нет, и заново его не определить.
	_Util_MarkSet("BackupPath", $sBackup, "DataPath", $g_sDataPath)

	; Внутри тома это переименование: гигабайты уезжают мгновенно
	If Not DirMove($g_sDataPath, $sBackup) Then
		_Util_MarkClear("BackupPath", "DataPath")

		; Причина почти всегда в держателе: его имя полезнее целевого пути
		Local $sBusy = _FolderNames(_FolderHolders($g_sDataPath))
		Return SetError(1, 0, ($sBusy = "") ? "целевой путь: " & $sBackup : "держат папку: " & $sBusy)
	EndIf

	Return $sBackup
EndFunc   ;==>_BackupUserData


; True - папка данных на месте или возвращать нечего
Func _RestoreUserData($sBackup)
	If $sBackup = "" Or Not FileExists($sBackup) Then Return True

	DirCreate(_Util_ParentDir($g_sDataPath))
	If Not DirMove($sBackup, $g_sDataPath) Then Return False

	_Util_MarkClear("BackupPath", "DataPath")
	Return True
EndFunc   ;==>_RestoreUserData


; Последствия прерванного прогона. Зовётся до _ApplyPaths: вынесенную папку data
; _DetectDataPath уже не найдёт и отправит данные в профиль - поэтому место берём из ini.
Func _RecoverInterrupted()
	_RecoverRenamed()

	Local $sBackup = IniRead($gc_sIniFile, "State", "BackupPath", "")
	Local $sDataPath = IniRead($gc_sIniFile, "State", "DataPath", "")
	If $sBackup = "" Then Return

	If Not FileExists($sBackup) Then ; вернули или убрали руками
		_Util_MarkClear("BackupPath", "DataPath")
		Return
	EndIf

	If $sDataPath = "" Then Return ; куда возвращать - неизвестно, не трогаем
	_Util_Log("Найден бэкап прерванного прогона: '" & $sBackup & "' → '" & $sDataPath & "'")

	If FileExists($sDataPath) Then
		Local $iAnswer = MsgBox(BitOR($MB_ICONWARNING, $MB_YESNO), $gc_sTitle, _
				"После прерванного обновления осталась папка:" & @CR & $sBackup & @CR & @CR & _
				"Папка данных при этом на месте. Удалить оставшуюся копию в корзину?")
		If $iAnswer = $IDYES And FileRecycle($sBackup) Then _Util_MarkClear("BackupPath", "DataPath")
		Return
	EndIf

	DirCreate(_Util_ParentDir($sDataPath))
	If DirMove($sBackup, $sDataPath) Then
		_Util_Log("Папка данных возвращена на место")
		_Util_MarkClear("BackupPath", "DataPath")
	Else
		_Util_Log("ОШИБКА: вернуть папку данных не удалось, метка в ini сохранена")
	EndIf
EndFunc   ;==>_RecoverInterrupted


; Старая версия переименовалась, но в корзину не уехала: возвращаем имя, иначе VS Code пропал
Func _RecoverRenamed()
	Local $sRenamed = IniRead($gc_sIniFile, "State", "RenamedPath", "")
	Local $sTarget = IniRead($gc_sIniFile, "State", "RenamedFrom", "")
	If $sRenamed = "" Or $sTarget = "" Then Return

	If FileExists($sRenamed) And Not FileExists($sTarget) Then
		_Util_Log("Возврат переименованной папки: '" & $sRenamed & "' → '" & $sTarget & "'")
		If Not DirMove($sRenamed, $sTarget) Then Return ; метка ждёт следующего запуска
	EndIf

	_Util_MarkClear("RenamedPath", "RenamedFrom")
EndFunc   ;==>_RecoverRenamed


; Переименовывает каталог VS Code с версией в имени и отправляет в корзину.
; Корзина недоступна (съёмный диск, отключена) - имя возвращаем, иначе рабочий
; VS Code остался бы под чужим названием.
Func _RemoveOldVersion()
	If Not FileExists($g_sTargetPath) Then Return True ; повтор после сбоя распаковки: сносить нечего

	Local $sRenamed = _Util_FreeName($g_sTargetPath & " " & (($g_sVerCur = "") ? _DateShort() : $g_sVerCur))

	; Метка на случай обрыва между переименованием и корзиной
	_Util_MarkSet("RenamedPath", $sRenamed, "RenamedFrom", $g_sTargetPath)
	If Not DirMove($g_sTargetPath, $sRenamed) Then
		_Util_MarkClear("RenamedPath", "RenamedFrom")
		Return False
	EndIf

	If FileRecycle($sRenamed) Then
		_Util_MarkClear("RenamedPath", "RenamedFrom")
		Return True
	EndIf

	; Не вернулось имя - метка остаётся, его вернёт _RecoverRenamed
	If DirMove($sRenamed, $g_sTargetPath) Then _Util_MarkClear("RenamedPath", "RenamedFrom")
	Return False
EndFunc   ;==>_RemoveOldVersion


; Запускает VS Code с аргументами лаунчера
Func _LaunchVSCode()
	If Not FileExists($g_sCodeExe) Then
		_Util_Log("ОШИБКА: запускать нечего, нет '" & $g_sCodeExe & "'")
		MsgBox($MB_ICONERROR, $gc_sTitle, "Не найден файл" & @CR & $g_sCodeExe)
		Exit 1
	EndIf

	; В терминале VS Code ELECTRON_RUN_AS_NODE=1, с ней Code.exe стартует как Node
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

; Свои ключи забирает, остальное уходит в Code.exe. Из $CmdLine, а не $CmdLineRaw:
; при запуске через AutoIt3.exe в Raw первым идёт путь к скрипту.
Func _ParseCmdLine()
	Local $sArgs = ""

	For $i = 1 To $CmdLine[0]
		Switch StringLower($CmdLine[$i])
			Case "/silent", "-silent", "--silent"
				$g_bSilent = True
			Case Else
				; кавычки снимаются при разборе, путям с пробелами их возвращаем
				$sArgs &= (StringInStr($CmdLine[$i], " ") ? '"' & $CmdLine[$i] & '"' : $CmdLine[$i]) & " "
		EndSwitch
	Next

	$g_sPassArgs = StringStripWS($sArgs, 3)
EndFunc   ;==>_ParseCmdLine


; ============================================================
; Утилиты
; ============================================================

; '1.134.0' против '1.135.0' по числам: 1 - первая новее, 0 - равны, -1 - старее.
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


; '84,6 из 319,3 МБ': одинаковую единицу у первого числа не повторяем
Func _FormatSizePair($iDone, $iTotal)
	Local $sDone = _FormatSize($iDone), $sTotal = _FormatSize($iTotal)
	Local $aDone = StringSplit($sDone, " ", 2), $aTotal = StringSplit($sTotal, " ", 2)

	If UBound($aDone) = 2 And UBound($aTotal) = 2 And $aDone[1] = $aTotal[1] Then Return $aDone[0] & " из " & $sTotal
	Return $sDone & " из " & $sTotal
EndFunc   ;==>_FormatSizePair


; $bRoundUp - для оценки остатка: 'осталось 0 сек' выглядит странно
Func _FormatTime($nSeconds, $bRoundUp = True)
	If $nSeconds >= 60 Then Return Int($nSeconds / 60) & " мин " & Int(Mod($nSeconds, 60)) & " сек"
	Return Int($nSeconds) + ($bRoundUp ? 1 : 0) & " сек"
EndFunc   ;==>_FormatTime


; Дробная часть через запятую: StringFormat в любой локали даёт точку
Func _Decimal($nValue, $iDigits)
	Return StringReplace(StringFormat("%." & $iDigits & "f", $nValue), ".", ",")
EndFunc   ;==>_Decimal


; Сегодня в виде '17.09.26' - для имён папок
Func _DateShort()
	Return @MDAY & "." & @MON & "." & StringRight(@YEAR, 2)
EndFunc   ;==>_DateShort


; На каком проценте оборвалась загрузка - подстрочник шага при ошибке
Func _DownloadedPercent()
	If $g_iZipSize <= 0 Then Return ""

	Local $iDone = _Util_FileSizeLive($g_sZipFile)
	If $iDone <= 0 Then Return ""
	Return "прервано на " & Int($iDone / $g_iZipSize * 100) & " %"
EndFunc   ;==>_DownloadedPercent


; Сколько лежит в недокачанном файле - для вопроса об обновлении
Func _DownloadedPart()
	Local $iSize = _Util_FileSizeLive($g_sZipFile)
	If $iSize <= 0 Then Return ""
	Return _FormatSize($iSize)
EndFunc   ;==>_DownloadedPart
