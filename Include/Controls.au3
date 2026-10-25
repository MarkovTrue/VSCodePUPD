#include-once

; ============================================================================
;  Controls.au3
;  Окна и контролы на библиотеке Fluent (соседний проект AutoitFluentSkin), тема
;  всегда тёмная. Кнопки - FluentButton, их надписи и доступность помнит этот модуль.
;  Здесь же метки, значки, ширины по тексту, обрезка путей и ответ окон ($g_iChoice, $g_bCancel).
; ============================================================================

#include <GUIConstantsEx.au3>
#include <StaticConstants.au3>
#include <WinAPI.au3>
#include <WinAPIGdi.au3>
#include <WindowsConstants.au3>

#include "..\..\AutoitFluentSkin\Include\FluentButton.au3"
#include "..\..\AutoitFluentSkin\Include\FluentInput.au3"
#include "..\..\AutoitFluentSkin\Include\FluentNativeEdit.au3"
#include "..\..\AutoitFluentSkin\Include\FluentNativeStatic.au3"
#include "..\..\AutoitFluentSkin\Include\FluentTheme.au3"

#include "Common.au3"

; Кнопки окон: [[ControlID, надпись, доступна, акцентная]]. FluentButton их наружу не отдаёт,
; а надпись и вид нужны для ширины кнопки и для выбора, ровнять ли ряд
Global $g_aDarkBtn[0][4]

; HBITMAP значков _DarkIconSet по ControlID: при перерисовке прежний освобождается
Global $g_mDarkIconBmp[]

; Ответ окна: 0 - ещё ждём, 1 - главная кнопка, 2 - отказ.
; $g_bCancelLocked закрывает выход на время, когда бросать работу нельзя.
Global $g_iChoice = 0
Global $g_bCancel = False, $g_bCancelLocked = False


; Ядро Fluent под новое окно, до первого контрола: оно меряет текст и держит палитру.
; Окно для замеров у ядра одно, поэтому каждое окно поднимает его заново
Func _DarkWindowInit($hWnd)
	Local Static $bStarted = False
	_FluentInit($hWnd, "Segoe UI", $gc_nFontBody)
	_FluentSetTheme(True)
	If Not $bStarted Then OnAutoItExitRegister("_FluentShutdown")
	$bStarted = True
EndFunc   ;==>_DarkWindowInit


; Тема окна после всех контролов: тёмный заголовок, фон, подписи и подсказки
Func _DarkWindowApply($hWnd)
	_FluentTheme_Apply($hWnd)
EndFunc   ;==>_DarkWindowApply


; Метки в одну строку встык, ширина каждой - по её шрифту: пробелы выглядят как в обычной строке.
; После высоты аргументы идут парами: ControlID, его текст.
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


; Размер клиентской области. WinMove задаёт внешний, а рамка зависит от темы и масштаба.
Func _ResizeClient($hWnd, $iWidth, $iHeight)
	Local $aWin = WinGetPos($hWnd)
	Local $aClient = WinGetClientSize($hWnd)
	If Not IsArray($aWin) Or Not IsArray($aClient) Then Return

	WinMove($hWnd, "", Default, Default, _
			$iWidth + ($aWin[2] - $aClient[0]), $iHeight + ($aWin[3] - $aClient[1]))
EndFunc   ;==>_ResizeClient


; Метка со своим фоном (полоса, трек прокрутки) - вне темы: тема сделала бы её прозрачной
Func _DarkLabel($sText, $iLeft, $iTop, $iWidth, $iHeight, $iColor, $iBkColor = -1, $iFontSize = $gc_nFontBody, $iWeight = 400, $iStyle = $SS_LEFTNOWORDWRAP)
	Local $iCtrl = GUICtrlCreateLabel($sText, $iLeft, $iTop, $iWidth, $iHeight, $iStyle)
	GUICtrlSetResizing($iCtrl, $GUI_DOCKALL) ; окно растёт под содержимое, метки при этом стоят на месте
	GUICtrlSetColor($iCtrl, $iColor)
	GUICtrlSetBkColor($iCtrl, ($iBkColor = -1) ? $GUI_BKCOLOR_TRANSPARENT : $iBkColor)
	If $iBkColor <> -1 Then _FluentTheme_Exclude($iCtrl)
	If $iFontSize <> $gc_nFontBody Or $iWeight <> 400 Then GUICtrlSetFont($iCtrl, $iFontSize, $iWeight, 0, "Segoe UI")
	Return $iCtrl
EndFunc   ;==>_DarkLabel


; Значок-картинка, рисует его _DarkIconSet. Квадратный: фигуры заданы в сетке 24x24
Func _DarkIcon($iLeft, $iTop, $iSize)
	Local $iCtrl = GUICtrlCreatePic("", $iLeft, $iTop, $iSize, $iSize)
	GUICtrlSetResizing($iCtrl, $GUI_DOCKALL)
	_FluentTheme_Exclude($iCtrl) ; картинка, а не подпись: перекрашивать нечего
	Return $iCtrl
EndFunc   ;==>_DarkIcon


; Фигуры Lucide линиями GDI+, как статусы Moth: check и x оттуда же, толщина 1,75 px
; на 14 px. Символы шрифта (✓, →) грубее и стоят не по середине строки, а PNG Moth
; берёт из папки тем, которой у одиночного exe нет.
; $sShape: check, x, wait (кольцо), run (точка), arrow (длинная стрелка вправо)
Func _DarkIconSet($iCtrl, $sShape, $iColor, $nStroke = 1.75)
	Local $aSize = _FluentCtrlSize($iCtrl)
	Local $nScale = $aSize[0] / 24
	Local $hGfx, $hCanvas = _FluentCanvas($aSize[0], $aSize[1], _FluentArgb($g_iFluentBg), $hGfx)

	Local $hPen = _GDIPlus_PenCreate(_FluentArgb($iColor), $nStroke)
	_GDIPlus_PenSetLineCap($hPen, $GDIP_LINECAPROUND, $GDIP_LINECAPROUND, $GDIP_DASHCAPROUND)
	_GDIPlus_PenSetLineJoin($hPen, $GDIP_PENSETLINEJOIN_ROUND)

	Switch $sShape
		Case "check"
			_DarkIconLines($hGfx, $hPen, $nScale, "20,6,9,17,4,12")
		Case "x"
			_DarkIconLines($hGfx, $hPen, $nScale, "18,6,6,18")
			_DarkIconLines($hGfx, $hPen, $nScale, "6,6,18,18")
		Case "arrow"
			; arrow-right с древком длиннее: стрелка между версиями читается как переход
			_DarkIconLines($hGfx, $hPen, $nScale, "3,12,21,12")
			_DarkIconLines($hGfx, $hPen, $nScale, "15,6,21,12,15,18")
		Case "wait"
			Local $nRing = 5 * $nScale
			_GDIPlus_GraphicsDrawEllipse($hGfx, 12 * $nScale - $nRing, 12 * $nScale - $nRing, 2 * $nRing, 2 * $nRing, $hPen)
		Case "run"
			Local $nDot = 6 * $nScale, $hBrush = _GDIPlus_BrushCreateSolid(_FluentArgb($iColor))
			_GDIPlus_GraphicsFillEllipse($hGfx, 12 * $nScale - $nDot, 12 * $nScale - $nDot, 2 * $nDot, 2 * $nDot, $hBrush)
			_GDIPlus_BrushDispose($hBrush)
	EndSwitch
	_GDIPlus_PenDispose($hPen)

	; Прежний HBITMAP значка освобождает _FluentCanvasApply. ControlID после GUIDelete
	; выдаются заново - тогда освобождается картинка погибшего окна, что тоже верно
	Local $hOld = MapExists($g_mDarkIconBmp, $iCtrl) ? $g_mDarkIconBmp[$iCtrl] : 0
	_FluentCanvasApply($iCtrl, $hOld, $hCanvas, $hGfx)
	$g_mDarkIconBmp[$iCtrl] = $hOld
EndFunc   ;==>_DarkIconSet


; Ломаная по точкам сетки 24x24: 'x1,y1,x2,y2,...'
Func _DarkIconLines($hGfx, $hPen, $nScale, $sPoints)
	Local $aXY = StringSplit($sPoints, ",", $STR_NOCOUNT)
	Local $iCount = Int(UBound($aXY) / 2)
	Local $aPoints[$iCount + 1][2]
	$aPoints[0][0] = $iCount
	For $i = 0 To $iCount - 1
		$aPoints[$i + 1][0] = $aXY[2 * $i] * $nScale
		$aPoints[$i + 1][1] = $aXY[2 * $i + 1] * $nScale
	Next
	; Одной фигурой пути, а не отрезками: иначе на изломе галочки нет скруглённого стыка
	Local $hPath = _GDIPlus_PathCreate()
	_GDIPlus_PathAddLine2($hPath, $aPoints)
	_GDIPlus_GraphicsDrawPath($hGfx, $hPath, $hPen)
	_GDIPlus_PathDispose($hPath)
EndFunc   ;==>_DarkIconLines


; Кнопка FluentButton: главная - акцентная, остальные - с рамкой. Ширина по надписи
Func _DarkButton($sText, $iLeft, $iTop, $bAccent = False)
	Local $iCtrl = _FluentButton_Create($sText, "", 0, $iLeft, $iTop, $gc_iBtnMinWidth, $gc_iBtnHeight, _
			$bAccent ? $FLUENTBUTTON_ACCENT : $FLUENTBUTTON_TEXT)

	Local $iIndex = UBound($g_aDarkBtn)
	ReDim $g_aDarkBtn[$iIndex + 1][4]
	$g_aDarkBtn[$iIndex][0] = $iCtrl
	$g_aDarkBtn[$iIndex][1] = $sText
	$g_aDarkBtn[$iIndex][2] = True
	$g_aDarkBtn[$iIndex][3] = $bAccent

	_FitButton($iCtrl, $iLeft, $iTop)
	Return $iCtrl
EndFunc   ;==>_DarkButton


Func _SetButtonText($iCtrl, $sText)
	Local $i = _DarkButtonIndex($iCtrl)
	If $i < 0 Then Return
	$g_aDarkBtn[$i][1] = $sText
	_FluentButton_SetText($iCtrl, $sText)
EndFunc   ;==>_SetButtonText


; Ширина кнопки по надписи, но не меньше стандартной. Акцентная пишет полужирным - шире
Func _FitButton($iCtrl, $iLeft, $iTop)
	Local $i = _DarkButtonIndex($iCtrl)
	If $i < 0 Then Return 0
	Local $hFont = _FluentFont(0, $g_aDarkBtn[$i][3])
	Local $iWidth = _FluentTextW($g_aDarkBtn[$i][1], $hFont) + 2 * $gc_iBtnPadX
	If $iWidth < $gc_iBtnMinWidth Then $iWidth = $gc_iBtnMinWidth

	_FluentButton_SetPos($iCtrl, $iLeft, $iTop, $iWidth, $gc_iBtnHeight)
	Return $iWidth
EndFunc   ;==>_FitButton


; Кнопки в ряд справа налево от $iRight, главная первой - она крайняя справа.
; Одной ширины - только при однословных надписях: 'Отмена', растянутая до
; 'Разблокировать и обновить', превращается в пустое поле.
Func _PlaceButtons($iRight, $iTop, $iBtn1, $iBtn2 = 0)
	Local $aBtn[2] = [$iBtn1, $iBtn2]
	Local $aWidth[2] = [0, 0]
	Local $bEqual = True

	For $i = 0 To 1
		If $aBtn[$i] = 0 Then ExitLoop
		$aWidth[$i] = _FitButton($aBtn[$i], 0, $iTop) ; ширину узнаём по надписи
		If StringInStr(StringStripWS(_DarkButtonText($aBtn[$i]), 3), " ") Then $bEqual = False
	Next

	If $bEqual And $aWidth[1] > $aWidth[0] Then $aWidth[0] = $aWidth[1]
	If $bEqual And $aWidth[0] > $aWidth[1] Then $aWidth[1] = $aWidth[0]

	Local $iX = $iRight
	For $i = 0 To 1
		If $aBtn[$i] = 0 Then ExitLoop
		$iX -= $aWidth[$i]
		_FluentButton_SetPos($aBtn[$i], $iX, $iTop, $aWidth[$i], $gc_iBtnHeight)
		$iX -= $gc_iBtnGap
	Next
EndFunc   ;==>_PlaceButtons


; Удаляет кнопки закрывающегося окна до его GUIDelete: реестр FluentButton переживает окно,
; а ControlID AutoIt выдаёт заново. Только свои: второе окно поднимается раньше,
; чем убрано первое, и его кнопки должны остаться живыми.
Func _DarkButtonDelete($iCtrl1, $iCtrl2 = 0, $iCtrl3 = 0)
	Local $aKeep[UBound($g_aDarkBtn)][4], $iCount = 0

	For $i = 0 To UBound($g_aDarkBtn) - 1
		Local $iCtrl = $g_aDarkBtn[$i][0]
		If $iCtrl = $iCtrl1 Or $iCtrl = $iCtrl2 Or $iCtrl = $iCtrl3 Then
			_FluentButton_Delete($iCtrl)
			ContinueLoop
		EndIf

		For $j = 0 To 3
			$aKeep[$iCount][$j] = $g_aDarkBtn[$i][$j]
		Next
		$iCount += 1
	Next

	ReDim $aKeep[$iCount][4]
	$g_aDarkBtn = $aKeep
EndFunc   ;==>_DarkButtonDelete


Func _SetButtonEnabled($iCtrl, $bEnabled)
	Local $i = _DarkButtonIndex($iCtrl)
	If $i < 0 Then Return
	$g_aDarkBtn[$i][2] = $bEnabled
	_FluentButton_SetEnabled($iCtrl, $bEnabled)
EndFunc   ;==>_SetButtonEnabled


Func _IsButtonEnabled($iCtrl)
	Local $i = _DarkButtonIndex($iCtrl)
	Return ($i < 0) ? False : $g_aDarkBtn[$i][2]
EndFunc   ;==>_IsButtonEnabled


Func _DarkButtonIndex($iCtrl)
	For $i = 0 To UBound($g_aDarkBtn) - 1
		If $g_aDarkBtn[$i][0] = $iCtrl Then Return $i
	Next
	Return -1
EndFunc   ;==>_DarkButtonIndex


Func _DarkButtonText($iCtrl)
	Local $i = _DarkButtonIndex($iCtrl)
	Return ($i < 0) ? "" : $g_aDarkBtn[$i][1]
EndFunc   ;==>_DarkButtonText


; Путь по ширине метки: не влезает - срезаем начало по границе папки и ставим многоточие.
; $iCtrl задаёт и ширину, и шрифт замера. $bQuote - одинарные кавычки: в подстрочнике
; отделяют путь от текста, в колонке таблицы отделять не от чего.
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


; Длинный путь режем посередине: начало говорит, куда смотреть ('VS Code\data'),
; хвост - что за папка. Голова - один или два сегмента, смотря по глубине.
; $sSep - разделитель: у путей '\', у адреса сервера '/'.
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


; Пауза, на которой окно живо: подсветка и крестик работают, в отличие от одного длинного Sleep
Func _Wait($iMs)
	Local $iTimer = TimerInit()
	While TimerDiff($iTimer) < $iMs
		Sleep(20)
		If $g_bCancel Then Return ; пользователь закрыл окно, ждать больше нечего
	WEnd
EndFunc   ;==>_Wait


; Крестик - то же, что отказ. На время переноса файлов сценарий поднимает $g_bCancelLocked.
Func _OnEvent_GUI_EVENT_CLOSE()
	If $g_bCancelLocked Then Return

	$g_bCancel = True
	$g_iChoice = 2
EndFunc   ;==>_OnEvent_GUI_EVENT_CLOSE


; Вторая кнопка: 'Отмена' в работе и после ошибки, 'Закрыть' после успеха.
; curl и 7-Zip закрывают сами модули, увидев отмену в колбэке.
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
