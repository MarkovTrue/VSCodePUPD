#include-once

; ============================================================================
;  Controls.au3
;  Тёмная тема на голых контролах: штатные кнопки Win32 тёмными не делаются,
;  поэтому кнопка здесь - это Label с ручной подсветкой. Отсюда же ширины по
;  тексту, обрезка длинных путей и общее состояние ответа: любое окно программы
;  отвечает через $g_iChoice и $g_bCancel.
; ============================================================================

#include <GUIConstantsEx.au3>
#include <StaticConstants.au3>
#include <WinAPI.au3>
#include <WinAPIGdi.au3>
#include <WindowsConstants.au3>

#include "Common.au3"

; Кнопки-Label под подсветку наведения: [[ControlID, базовый цвет, цвет наведения, доступна]]
Global $g_aHotBtn[0][4]

; Ответ окна: 0 - ещё ждём, 1 - главная кнопка, 2 - отказ.
; $g_bCancelLocked закрывает выход на время, когда бросать работу нельзя.
Global $g_iChoice = 0
Global $g_bCancel = False, $g_bCancelLocked = False


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
	GUICtrlSetResizing($iCtrl, $GUI_DOCKALL) ; окно растёт под содержимое, метки при этом стоят на месте
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
	GUICtrlSetResizing($iCtrl, $GUI_DOCKALL)
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
;
; Одинаковая ширина работает, только пока надписи короткие, в одно слово:
; рядом с 'Разблокировать и обновить' растянутая до неё 'Отмена' - это кнопка
; из сплошного пустого поля. Появилось в ряду многословие - каждый по себе.
Func _PlaceButtons($iRight, $iTop, $iBtn1, $iBtn2 = 0)
	Local $aBtn[2] = [$iBtn1, $iBtn2]
	Local $aWidth[2] = [0, 0]
	Local $bEqual = True

	For $i = 0 To 1
		If $aBtn[$i] = 0 Then ExitLoop
		$aWidth[$i] = _FitButton($aBtn[$i], 0, $iTop) ; ширину узнаём по надписи
		If StringInStr(StringStripWS(GUICtrlRead($aBtn[$i]), 3), " ") Then $bEqual = False
	Next

	If $bEqual And $aWidth[1] > $aWidth[0] Then $aWidth[0] = $aWidth[1]
	If $bEqual And $aWidth[0] > $aWidth[1] Then $aWidth[1] = $aWidth[0]

	Local $iX = $iRight
	For $i = 0 To 1
		If $aBtn[$i] = 0 Then ExitLoop
		$iX -= $aWidth[$i]
		GUICtrlSetPos($aBtn[$i], $iX, $iTop, $aWidth[$i], $gc_iBtnHeight)
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


; Забыть кнопки закрывающегося окна. Чистить список целиком нельзя: второе окно
; поднимается ДО того, как убрать первое, и его кнопки уже стоят в списке -
; вместе с ними пропадала бы и подсветка, и признак 'кнопка доступна', из-за
; которого 'Повторить' переставала нажиматься.
Func _HotBtnForget($iCtrl1, $iCtrl2 = 0, $iCtrl3 = 0)
	Local $aKeep[UBound($g_aHotBtn)][4], $iCount = 0

	For $i = 0 To UBound($g_aHotBtn) - 1
		Local $iCtrl = $g_aHotBtn[$i][0]
		If $iCtrl = $iCtrl1 Or $iCtrl = $iCtrl2 Or $iCtrl = $iCtrl3 Then ContinueLoop

		For $j = 0 To 3
			$aKeep[$iCount][$j] = $g_aHotBtn[$i][$j]
		Next
		$iCount += 1
	Next

	ReDim $aKeep[$iCount][4]
	$g_aHotBtn = $aKeep
EndFunc   ;==>_HotBtnForget


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


Func _IsButtonEnabled($iCtrl)
	For $i = 0 To UBound($g_aHotBtn) - 1
		If $g_aHotBtn[$i][0] = $iCtrl Then Return $g_aHotBtn[$i][3]
	Next
	Return False
EndFunc   ;==>_IsButtonEnabled


; Путь в кавычках-ёлочках по ширине метки: не влезает - срезаем начало
; по границе папки и начинаем с многоточия. Одна функция на оба окна:
; раньше их было две с разными алгоритмами обрезки.
;
; $iCtrl задаёт и ширину, и шрифт замера, поэтому окно ищем по самому контролу.
; $bQuote - кавычки вокруг пути: в подстрочнике они отделяют путь от текста,
; в колонке таблицы отделять не от чего.
Func _FitPath($iCtrl, $sPath, $sPrefix = "", $bQuote = True)
	Local $sQ = $bQuote ? "'" : ""
	Local $sFull = $sPrefix & $sQ & $sPath & $sQ

	Local $aPos = ControlGetPos(_WinAPI_GetParent(GUICtrlGetHandle($iCtrl)), "", $iCtrl)
	If Not IsArray($aPos) Or _TextWidth($iCtrl, $sFull) <= $aPos[2] Then Return $sFull

	; Сначала по границам папок: '...\Code\data' читается лучше обрубка посреди слова
	Local $sCut = $sPath
	While StringInStr($sCut, '\')
		$sCut = StringTrimLeft($sCut, StringInStr($sCut, '\'))
		If _TextWidth($iCtrl, $sPrefix & $sQ & "...\" & $sCut & $sQ) <= $aPos[2] Then _
				Return $sPrefix & $sQ & "...\" & $sCut & $sQ
	WEnd

	; Разделителей не осталось, а строка всё ещё не влезает - режем посимвольно
	While StringLen($sCut) > 12 And _TextWidth($iCtrl, $sPrefix & $sQ & "..." & $sCut & $sQ) > $aPos[2]
		$sCut = StringTrimLeft($sCut, 4)
	WEnd

	Return $sPrefix & $sQ & "..." & $sCut & $sQ
EndFunc   ;==>_FitPath


; Длинный путь в колонке режем посередине, а не с краю: начало говорит, куда
; смотреть ('VS Code\data'), хвост - что это за папка. Обрубок с одного края
; теряет то или другое, а внутри VS Code вложенность такая, что не влезает почти
; ничего. Голову держим в две ступени - диск с папкой или 'VS Code\data'.
; $sSep - разделитель: у путей это слэш, у адреса сервера обычный.
Func _FitMiddle($iCtrl, $sPath, $sSep = "\")
	Local $aPos = ControlGetPos(_WinAPI_GetParent(GUICtrlGetHandle($iCtrl)), "", $iCtrl)
	If Not IsArray($aPos) Or _TextWidth($iCtrl, $sPath) <= $aPos[2] Then Return $sPath

	Local $aPart = StringSplit($sPath, $sSep, $STR_NOCOUNT)
	Local $iHead = (UBound($aPart) > 4) ? 2 : 1

	Local $sHead = ""
	For $i = 0 To $iHead - 1
		$sHead &= $aPart[$i] & $sSep
	Next

	; Хвост наращиваем с конца, пока строка влезает в колонку
	Local $sBest = ""
	For $i = UBound($aPart) - 1 To $iHead Step -1
		Local $sTail = $aPart[$i] & ($sBest = "" ? "" : $sSep & $sBest)
		If _TextWidth($iCtrl, $sHead & "..." & $sSep & $sTail) > $aPos[2] Then ExitLoop
		$sBest = $sTail
	Next

	; Не влез даже один сегмент - показываем хотя бы конец пути
	If $sBest = "" Then Return _FitPath($iCtrl, $sPath, "", False)

	Return $sHead & "..." & $sSep & $sBest
EndFunc   ;==>_FitMiddle


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


; Крестик окна: то же, что отказ. Пока идёт перенос файлов, закрываться нельзя -
; на это время сценарий поднимает $g_bCancelLocked.
Func _OnEvent_GUI_EVENT_CLOSE()
	If $g_bCancelLocked Then Return

	$g_bCancel = True
	$g_iChoice = 2
EndFunc   ;==>_OnEvent_GUI_EVENT_CLOSE


; Вторая кнопка: до начала переноса файлов это 'Отмена', после успеха - 'Закрыть',
; после ошибки - 'Запустить как есть'. Дочерние процессы (curl, 7-Zip) закрывают
; сами модули, когда видят отмену через колбэк - здесь достаточно поднять флаг.
Func _OnEvent_ButtonAlt()
	If $g_bCancelLocked Then Return

	$g_bCancel = True
EndFunc   ;==>_OnEvent_ButtonAlt


Func _OnEvent_ChoiceUpdate()
	$g_iChoice = 1
EndFunc   ;==>_OnEvent_ChoiceUpdate


Func _OnEvent_ChoiceRun()
	$g_iChoice = 2
EndFunc   ;==>_OnEvent_ChoiceRun
