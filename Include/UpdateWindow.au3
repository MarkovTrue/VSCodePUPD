#include-once

; ============================================================================
;  UpdateWindow.au3
;  Второе окно лаунчера: сам ход обновления галочками по шагам. Список шагов
;  строится под конкретный случай - без папки данных внутри VS Code переносить
;  нечего, и два шага из семи просто не нужны.
; ============================================================================

#include <GUIConstantsEx.au3>
#include <StaticConstants.au3>
#include <WindowsConstants.au3>

#include "Common.au3"
#include "Controls.au3"
#include "Util.au3"

Global $g_hMain = 0, $g_iHero, $g_iHeroArrow, $g_iHeroNew, $g_iHeroSub, $g_iBarBg, $g_iBar
Global $g_iStatus, $g_iStatusInfo
Global $g_iBtnMain = 0, $g_iBtnAlt = 0
Global $g_iBarTop = 0, $g_iButtonTop = 0 ; считаются от числа шагов при построении окна
Global $g_aMarker[1], $g_aStepLabel[1], $g_aStepSub[1]

; Геометрия окна: шаги начинаются с $gc_iStepTop и идут с шагом $gc_iStepPitch
Global Const $gc_iMainWidth = 520
Global Const $gc_iStepTop = 82, $gc_iStepPitch = 24
Global Const $gc_iBarLeft = $gc_iPad, $gc_iBarWidth = $gc_iMainWidth - 2 * $gc_iPad, $gc_iBarHeight = 6
Global Const $gc_iBtnRight = $gc_iMainWidth - $gc_iPad
; Колонка с подробностями шага, выравнивание по правому краю. Отсчёт от самого
; длинного названия ('Возврат папки пользователя', 181 px), иначе оно налезло бы
; на подстрочник.
Global Const $gc_iStepInfoLeft = 240
Global Const $gc_iStepTitleWidth = $gc_iStepInfoLeft - 44 - 8

Global Const $gc_sMarkWait = ChrW(0x25CB) ; ○
Global Const $gc_sMarkRun = ChrW(0x25CF)  ; ●
Global Const $gc_sMarkDone = ChrW(0x2713) ; ✓
Global Const $gc_sMarkErr = ChrW(0x2715)  ; ✕

; Список шагов зависит от того, лежит ли папка данных внутри VS Code,
; поэтому собирается в _BuildSteps. Сверка SHA-256 своего пункта не имеет:
; она часть шага загрузки.
Global $g_aStepTitle[1] = [""], $g_aStepWeight[1] = [100]
Global $g_iStepDownload = 1, $g_iStepBackup = -1, $g_iStepRemove = 2
Global $g_iStepUnpack = 3, $g_iStepRestore = -1

; Полный список шагов: [ключ, заголовок, вес, нужен только при данных внутри].
; Индексы шагов выводятся из него, поэтому при правке списка ничего
; больше подкручивать не надо.
Global Const $gc_aStepPlan[6][4] = [ _
		["check", "Проверка обновления", 3, False], _
		["download", "Загрузка архива", 46, False], _
		["backup", "Копия папки пользователя", 3, True], _
		["remove", "Удаление старой версии", 10, False], _
		["unpack", "Распаковка архива", 32, False], _
		["restore", "Возврат папки пользователя", 6, True]]

; Итоги завершённых шагов: показываются подстрочником рядом с пунктом
Global $g_sDownloadSummary = "", $g_sUnpackSummary = ""


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

	; Под версиями - только папка, которую обновляем: имя архива и его размер
	; человек уже видел в первом окне, повторять их здесь незачем
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hMain)
	$g_iHeroSub = _DarkLabel("", $gc_iBarLeft, 54, $gc_iBarWidth, 18, $gc_iClrDim, -1, $gc_nFontCaption)
	GUICtrlSetData($g_iHeroSub, _FitPath($g_iHeroSub, $g_sTargetPath, "", False))

	; --- Шаги ---
	Local $iTop = $gc_iStepTop
	For $i = 0 To UBound($g_aStepTitle) - 1
		$g_aMarker[$i] = _DarkLabel($gc_sMarkWait, 22, $iTop, 18, 20, $gc_iClrWait)
		$g_aStepLabel[$i] = _DarkLabel($g_aStepTitle[$i], 44, $iTop, $gc_iStepTitleWidth, 20, $gc_iClrWait)
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

	GUISetOnEvent($GUI_EVENT_CLOSE, "_OnEvent_GUI_EVENT_CLOSE", $g_hMain)
	GUICtrlSetOnEvent($g_iBtnMain, "_OnEvent_ButtonMain")
	GUICtrlSetOnEvent($g_iBtnAlt, "_OnEvent_ButtonAlt")

	GUISetState(@SW_SHOW, $g_hMain)
EndFunc   ;==>_MainGUI


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


Func _OnEvent_ButtonMain()
	If Not _IsButtonEnabled($g_iBtnMain) Then Return
	$g_iChoice = 1
EndFunc   ;==>_OnEvent_ButtonMain


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
