#include-once

; ============================================================================
;  StartWindow.au3
;  Первое окно лаунчера. Одно на все состояния до начала обновления: проверка
;  сервера, новая версия, список тех, кто держит папку, и сама разблокировка.
;  Окно не пересоздаётся между ними - меняются надписи, кнопки и высота,
;  иначе человек видел бы моргание вместо продолжения разговора.
;
;  Логика занятости и разблокировки лежит в Util.au3, здесь только показ.
; ============================================================================

#include <GUIConstantsEx.au3>
#include <StaticConstants.au3>
#include <WinAPI.au3>
#include <WindowsConstants.au3>

#include "Common.au3"
#include "Controls.au3"
#include "Util.au3"

Global $g_hStart = 0, $g_iStartTitle, $g_iStartSub, $g_iStartBarBg, $g_iStartBar
Global $g_iStartBtnMain = 0, $g_iStartBtnAlt = 0

; Заголовок вопроса о версии: три метки, потому что версия внутри строки цветная
Global $g_iStartHead = 0, $g_iStartVer = 0, $g_iStartTail = 0

; Таблица держателей папки. Создаётся, только если папку и правда держат:
; в остальных состояниях окно остаётся низким.
Global $g_aStartRows[0][4] ; [имя, папка, путь к exe, сколько процессов]
Global $g_aStartIcon[0], $g_aStartName[0], $g_aStartPath[0] ; контролы видимых строк
Global $g_iStartTrack = 0, $g_iStartThumb = 0
Global $g_iStartRow = 0 ; первая видимая строка при прокрутке
Global $g_iStartSlots = 0 ; сколько мест в таблице показано, задаётся при показе списка

; Зона под надписями: при проверке там полоса, при вопросе - кнопки
Global Const $gc_iStartActionTop = 72
Global Const $gc_iStartHeight = $gc_iStartActionTop + $gc_iBtnHeight + 22

; Таблица держателей: строк не больше $gc_iStartMaxRows, дальше прокрутка
Global Const $gc_iStartMaxRows = 5, $gc_iStartPitch = 24
Global Const $gc_iStartTableTop = 76
Global Const $gc_iStartNameLeft = 44, $gc_iStartNameWidth = 140
Global Const $gc_iStartPathLeft = $gc_iStartNameLeft + $gc_iStartNameWidth + 12
Global Const $gc_iStartBarWidth = 6 ; полоса прокрутки справа от таблицы

; Заголовок всех состояний с таблицей: он не меняется от вопроса до отказа
Global Const $gc_sStartLocked = "Папка VS Code заблокирована"

; Иконка строки, когда в самом exe её нет: почти всегда это консольная утилита,
; и значок консоли подходит по смыслу лучше безликой заглушки
Global Const $gc_sIconStub = @SystemDir & "\cmd.exe"


; Окно проверки: поверх остальных, без кнопки на панели задач.
;
; Все контролы строятся сразу и прячутся - и кнопки, и заголовок вопроса,
; и строки таблицы. Досоздавать их потом нельзя: контрол, созданный после
; GUISwitch, получает координаты с чужим масштабом (проверено - строка уезжала
; с y=78 на y=137), и таблица налезала на кнопки.
Func _StartGUI()
	$g_hStart = GUICreate($gc_sTitle, $gc_iPopupWidth, $gc_iStartHeight, -1, -1, _
			BitOR($WS_POPUP, $WS_CAPTION, $WS_SYSMENU), $WS_EX_TOPMOST)
	GUISetBkColor($gc_iClrBg, $g_hStart)
	GUISetFont($gc_nFontBody, 400, 0, "Segoe UI", $g_hStart)
	_GUISetDarkTitleBar($g_hStart)

	Local $iWidth = $gc_iPopupWidth - 2 * $gc_iPad
	$g_iStartTitle = _DarkLabel("Проверка обновлений...", $gc_iPad, $gc_iPad, $iWidth, 20, $gc_iClrText)
	$g_iStartSub = _DarkLabel("", $gc_iPad, 46, $iWidth, 18, $gc_iClrDim, -1, $gc_nFontCaption)
	$g_iStartBarBg = _DarkLabel("", $gc_iPad, $gc_iStartActionTop + 13, $iWidth, 6, $gc_iClrText, $gc_iClrBarBg)
	$g_iStartBar = _DarkLabel("", $gc_iPad, $gc_iStartActionTop + 13, 0, 6, $gc_iClrText, $gc_iClrBar)

	; Заголовок вопроса о версии: три метки, потому что версия внутри строки цветная
	$g_iStartHead = _DarkLabel("", $gc_iPad, $gc_iPad, 10, 20, $gc_iClrText)
	$g_iStartVer = _DarkLabel("", $gc_iPad, $gc_iPad, 10, 20, $gc_iClrRun)
	GUICtrlSetFont($g_iStartVer, $gc_nFontBody, 600, 0, "Segoe UI")
	$g_iStartTail = _DarkLabel("", $gc_iPad, $gc_iPad, 10, 20, $gc_iClrText)
	_StartShow(False, $g_iStartHead, $g_iStartVer, $g_iStartTail)

	; Строки таблицы держателей и полоса прокрутки к ним
	ReDim $g_aStartIcon[$gc_iStartMaxRows]
	ReDim $g_aStartName[$gc_iStartMaxRows]
	ReDim $g_aStartPath[$gc_iStartMaxRows]

	For $i = 0 To $gc_iStartMaxRows - 1
		Local $iY = $gc_iStartTableTop + $i * $gc_iStartPitch
		$g_aStartIcon[$i] = GUICtrlCreateIcon($gc_sIconStub, 0, $gc_iPad, $iY + 3, 16, 16)
		GUICtrlSetResizing($g_aStartIcon[$i], $GUI_DOCKALL)
		$g_aStartName[$i] = _DarkLabel("", $gc_iStartNameLeft, $iY + 2, $gc_iStartNameWidth, 18, $gc_iClrText)
		$g_aStartPath[$i] = _DarkLabel("", $gc_iStartPathLeft, $iY + 4, _
				$gc_iPopupWidth - $gc_iStartPathLeft - $gc_iPad, 16, $gc_iClrDim, -1, $gc_nFontCaption)
		_StartShow(False, $g_aStartIcon[$i], $g_aStartName[$i], $g_aStartPath[$i])
	Next

	Local $iBarLeft = $gc_iPopupWidth - $gc_iPad - $gc_iStartBarWidth
	; трек кликабельный: колесо есть не у всех, а листать чем-то надо
	$g_iStartTrack = _DarkLabel("", $iBarLeft, $gc_iStartTableTop, $gc_iStartBarWidth, _
			$gc_iStartMaxRows * $gc_iStartPitch, $gc_iClrText, $gc_iClrBarBg, $gc_nFontBody, 400, $SS_NOTIFY)
	$g_iStartThumb = _DarkLabel("", $iBarLeft, $gc_iStartTableTop, $gc_iStartBarWidth, _
			$gc_iStartMaxRows * $gc_iStartPitch, $gc_iClrText, $gc_iClrBtnDisText)
	_StartShow(False, $g_iStartTrack, $g_iStartThumb)

	$g_iStartBtnMain = _DarkButton("Обновить", 0, $gc_iStartActionTop, True)
	$g_iStartBtnAlt = _DarkButton("Пропустить", 0, $gc_iStartActionTop)
	_StartShow(False, $g_iStartBtnMain, $g_iStartBtnAlt)

	GUISetOnEvent($GUI_EVENT_CLOSE, "_OnEvent_GUI_EVENT_CLOSE", $g_hStart)
	GUICtrlSetOnEvent($g_iStartBtnMain, "_OnEvent_ChoiceUpdate")
	GUICtrlSetOnEvent($g_iStartBtnAlt, "_OnEvent_ChoiceRun")
	GUICtrlSetOnEvent($g_iStartTrack, "_OnEvent_StartTrack")
	GUIRegisterMsg($WM_MOUSEWHEEL, "_OnStartWheel")

	; Адрес сервера показываем целиком, насколько влезает: схема одна и та же
	; у всех, а вот платформа и канал в хвосте - это то, что стоит видеть.
	; Полный адрес остаётся в подсказке.
	Local $sApi = StringReplace($gc_sUpdateApi, "https://", "")
	_StartSub(_FitMiddle($g_iStartSub, $sApi, "/"), $gc_sUpdateApi)

	GUISetState(@SW_SHOW, $g_hStart)
EndFunc   ;==>_StartGUI


; Показать или спрятать сразу несколько контролов: в этом окне они ходят группами
Func _StartShow($bShow, $iCtrl1, $iCtrl2 = 0, $iCtrl3 = 0)
	Local $aCtrl[3] = [$iCtrl1, $iCtrl2, $iCtrl3]

	For $i = 0 To 2
		If $aCtrl[$i] = 0 Then ContinueLoop
		GUICtrlSetState($aCtrl[$i], $bShow ? $GUI_SHOW : $GUI_HIDE)
	Next
EndFunc   ;==>_StartShow


; Надписи и полоса во всю ширину: это конец работы, а не прогресс, поэтому
; цвет полосы берём у сообщения - синяя под отказом читалась бы как успех.
Func _StartState($sText, $sSub, $iColor = $gc_iClrText)
	GUICtrlSetData($g_iStartTitle, $sText)
	GUICtrlSetColor($g_iStartTitle, $iColor)
	_StartSub($sSub)

	GUICtrlSetBkColor($g_iStartBar, ($iColor = $gc_iClrText) ? $gc_iClrBar : $iColor)
	GUICtrlSetPos($g_iStartBar, $gc_iPad, $gc_iStartActionTop + 13, $gc_iPopupWidth - 2 * $gc_iPad, 6)
EndFunc   ;==>_StartState


; Отдельно от _StartState: пока идёт разблокировка, подстрочник обновляется
; каждые полсекунды, а трогать из-за счётчика заголовок и кнопки незачем.
; $sTip - что показать по наведению, когда строка не влезла целиком.
Func _StartSub($sText, $sTip = "")
	GUICtrlSetData($g_iStartSub, $sText)
	GUICtrlSetTip($g_iStartSub, $sTip)
EndFunc   ;==>_StartSub


; Бегунок неопределённого прогресса: ползёт слева направо, пока идёт запрос к API.
Func _StartPulse()
	Local Static $iPos = 0
	$iPos = Mod($iPos + 6, $gc_iPopupWidth - 2 * $gc_iPad + 100)
	Local $iTrack = $gc_iPopupWidth - 2 * $gc_iPad
	Local $iLeft = $gc_iPad + (($iPos > 100) ? $iPos - 100 : 0)
	Local $iWidth = ($iPos < 100) ? $iPos : (($iPos > $iTrack) ? $iTrack + 100 - $iPos : 100)
	GUICtrlSetPos($g_iStartBar, $iLeft, $gc_iStartActionTop + 13, $iWidth, 6)
EndFunc   ;==>_StartPulse


; Вопрос 'Обновить / Пропустить'. Кнопки встают в ту же зону, где была полоса,
; поэтому окно не меняет размер. Возвращает 1 - обновлять, 2 - запускать как есть.
Func _StartAskVersion()
	; Имя архива и его размер через ту же точку, что и в окне обновления:
	; по имени видно платформу и версию, по размеру - сколько ждать
	Local $sDot = "  " & ChrW(0x2022) & "  "
	Local $sSize = _Util_FileName($g_sZipFile)
	If $g_iZipSize > 0 Then $sSize &= $sDot & _FormatSize($g_iZipSize)

	Local $sDone = _DownloadedPart()
	If $sDone <> "" Then $sSize &= $sDot & "уже загружено " & $sDone

	; Заголовок из трёх меток, склеенных по фактической ширине текста: пробелы
	; должны читаться как в обычной строке, а не как отступы между контролами
	Local $sHead = "Доступна новая версия ", $sTail = "  текущая " & $g_sVerCur
	GUICtrlSetData($g_iStartHead, $sHead)
	GUICtrlSetData($g_iStartVer, $g_sVerNew)
	GUICtrlSetData($g_iStartTail, $sTail)
	_LayoutRow($gc_iPad, $gc_iPad, 20, $g_iStartHead, $sHead, $g_iStartVer, $g_sVerNew, $g_iStartTail, $sTail)

	_StartShow(False, $g_iStartTitle, $g_iStartBarBg, $g_iStartBar)
	_StartShow(True, $g_iStartHead, $g_iStartVer, $g_iStartTail)
	_StartSub($sSize)
	_StartButtons("Обновить", "Пропустить", $gc_iStartActionTop)

	Return _StartWait()
EndFunc   ;==>_StartAskVersion


; Разворачивает окно в список держателей: показывает столько строк, сколько
; нужно, и вытягивает высоту под них. Высота считается один раз - строки во
; время разблокировки исчезают одна за другой, и окно прыгало бы под курсором.
Func _StartHolders($aRows)
	$g_aStartRows = $aRows
	$g_iStartRow = 0

	Local $iVisible = UBound($aRows)
	If $iVisible > $gc_iStartMaxRows Then $iVisible = $gc_iStartMaxRows
	If $iVisible < 1 Then $iVisible = 1

	_StartShow(False, $g_iStartBarBg, $g_iStartBar)

	; Полоса прокрутки нужна, только когда строк больше, чем помещается,
	; и тогда же колонка пути ужимается, чтобы не лезть под неё
	Local $bScroll = UBound($aRows) > $gc_iStartMaxRows
	Local $iPathWidth = $gc_iPopupWidth - $gc_iStartPathLeft - $gc_iPad - ($bScroll ? $gc_iStartBarWidth + 8 : 0)

	For $i = 0 To $gc_iStartMaxRows - 1
		If $i >= $iVisible Then ContinueLoop ; лишние места так и остаются скрытыми

		Local $iY = $gc_iStartTableTop + $i * $gc_iStartPitch
		GUICtrlSetPos($g_aStartPath[$i], $gc_iStartPathLeft, $iY + 4, $iPathWidth, 16)
		_StartShow(True, $g_aStartIcon[$i], $g_aStartName[$i], $g_aStartPath[$i])
	Next

	If $bScroll Then
		Local $iTrack = $iVisible * $gc_iStartPitch
		GUICtrlSetPos($g_iStartTrack, $gc_iPopupWidth - $gc_iPad - $gc_iStartBarWidth, $gc_iStartTableTop, _
				$gc_iStartBarWidth, $iTrack)
		_StartShow(True, $g_iStartTrack, $g_iStartThumb)
	EndIf

	$g_iStartSlots = $iVisible
	_StartResize($gc_iStartTableTop + $iVisible * $gc_iStartPitch + 18)
	_StartRedraw()
EndFunc   ;==>_StartHolders


; Тянет окно под новую высоту, оставляя его на месте по центру: рост только
; вниз увёл бы окно из середины экрана.
Func _StartResize($iBtnTop)
	Local $iHeight = $iBtnTop + $gc_iBtnHeight + $gc_iPad
	Local $aPos = WinGetPos($g_hStart)
	Local $aClient = WinGetClientSize($g_hStart)
	If Not IsArray($aPos) Or Not IsArray($aClient) Then Return

	_ResizeClient($g_hStart, $gc_iPopupWidth, $iHeight)
	WinMove($g_hStart, "", $aPos[0], $aPos[1] - Int(($iHeight - $aClient[1]) / 2))
EndFunc   ;==>_StartResize


; Перерисовывает видимую часть таблицы под текущую прокрутку.
; Иконку берём из самого exe процесса: у консольных утилит её там нет,
; тогда остаётся значок консоли.
Func _StartRedraw()
	For $i = 0 To $g_iStartSlots - 1
		Local $iRow = $g_iStartRow + $i

		; Строк может стать меньше, чем мест: процессы гибнут по одному
		If $iRow >= UBound($g_aStartRows) Then
			_StartShow(False, $g_aStartIcon[$i])
			GUICtrlSetData($g_aStartName[$i], "")
			GUICtrlSetData($g_aStartPath[$i], "")
			ContinueLoop
		EndIf

		_StartShow(True, $g_aStartIcon[$i])
		GUICtrlSetImage($g_aStartIcon[$i], ($g_aStartRows[$iRow][2] = "") ? $gc_sIconStub : $g_aStartRows[$iRow][2], 0)

		Local $sName = $g_aStartRows[$iRow][0]
		If $g_aStartRows[$iRow][3] > 1 Then $sName &= "  ×" & $g_aStartRows[$iRow][3]
		GUICtrlSetData($g_aStartName[$i], $sName)

		; Путь показываем полностью, а не влезает - режем и вешаем подсказку:
		; в колонке видно главное, полный путь остаётся в одном наведении
		Local $sPath = $g_aStartRows[$iRow][1]
		Local $sFit = _FitMiddle($g_aStartPath[$i], $sPath)
		GUICtrlSetData($g_aStartPath[$i], $sFit)
		GUICtrlSetTip($g_aStartPath[$i], ($sFit = $sPath) ? "" : $sPath)
	Next

	_StartThumb()
EndFunc   ;==>_StartRedraw


; Бегунок прокрутки: высота - доля видимого, положение - доля пролистанного
Func _StartThumb()
	If $g_iStartThumb = 0 Then Return

	Local $iVisible = $g_iStartSlots, $iTotal = UBound($g_aStartRows)
	Local $iLeft = $gc_iPopupWidth - $gc_iPad - $gc_iStartBarWidth
	Local $iTrack = $iVisible * $gc_iStartPitch

	If $iTotal <= $iVisible Then ; закрыли столько, что прокрутка больше не нужна
		GUICtrlSetPos($g_iStartThumb, $iLeft, $gc_iStartTableTop, $gc_iStartBarWidth, $iTrack)
		Return
	EndIf

	Local $iHeight = Int($iTrack * $iVisible / $iTotal)
	If $iHeight < 16 Then $iHeight = 16
	Local $iTop = $gc_iStartTableTop + Int(($iTrack - $iHeight) * $g_iStartRow / ($iTotal - $iVisible))

	GUICtrlSetPos($g_iStartThumb, $iLeft, $iTop, $gc_iStartBarWidth, $iHeight)
EndFunc   ;==>_StartThumb


; Прокрутка на $iStep строк с упором в края списка
Func _StartScroll($iStep)
	Local $iMax = UBound($g_aStartRows) - $g_iStartSlots
	If $iMax <= 0 Then Return

	Local $iNew = $g_iStartRow + $iStep
	If $iNew < 0 Then $iNew = 0
	If $iNew > $iMax Then $iNew = $iMax
	If $iNew = $g_iStartRow Then Return

	$g_iStartRow = $iNew
	_StartRedraw()
EndFunc   ;==>_StartScroll


; Новый список во время разблокировки: строки тают, а прокрутка не должна
; повиснуть за концом списка.
Func _StartSetRows($aRows)
	$g_aStartRows = $aRows

	Local $iMax = UBound($g_aStartRows) - $g_iStartSlots
	If $g_iStartRow > $iMax Then $g_iStartRow = ($iMax > 0) ? $iMax : 0

	_StartRedraw()
EndFunc   ;==>_StartSetRows


; Состояния списка держателей: таблица и жёлтый заголовок остаются на месте,
; меняются подстрочник и кнопки. Заголовок не переписываем на 'разблокируем':
; человек и так видит, что происходит, а прыгающая строка сверху только мешает.
Func _StartMode($sMode, $sSub = "")
	Local $iBtnTop = $gc_iStartTableTop + $g_iStartSlots * $gc_iStartPitch + 18

	Switch $sMode
		Case "ask"
			_StartState($gc_sStartLocked, _
					($sSub <> "") ? $sSub : "Закрыть принудительно процессы и разблокировать папку?", $gc_iClrWarn)
			_StartButtons("Разблокировать и обновить", "Отмена", $iBtnTop)

		Case "closing"
			; Заголовок тот же, что и в вопросе: папка всё ещё заблокирована,
			; и переписывать строку на 'разблокируем' - только дёргать глаз
			_StartState($gc_sStartLocked, _
					($sSub <> "") ? $sSub : "Осталось процессов: " & _StartProcessCount(), $gc_iClrWarn)
			_StartButtons("", "Отмена", $iBtnTop)

		Case "fail"
			_StartState("Не удалось освободить папку", _
					($sSub <> "") ? $sSub : "Эти процессы не закрылись даже принудительно", $gc_iClrWarn)
			_StartButtons("Повторить", "Отмена", $iBtnTop)
	EndSwitch
EndFunc   ;==>_StartMode


; Сколько процессов стоит за строками таблицы: строка склеивает одноимённые,
; а счётчик в подстрочнике считает их поштучно
Func _StartProcessCount()
	Local $iCount = 0
	For $i = 0 To UBound($g_aStartRows) - 1
		$iCount += $g_aStartRows[$i][3]
	Next

	Return $iCount
EndFunc   ;==>_StartProcessCount


; Показывает кнопки состояния. Пустая надпись главной - выбора нет,
; остаётся одна 'Отмена'.
Func _StartButtons($sMain, $sAlt, $iTop)
	GUICtrlSetData($g_iStartBtnAlt, $sAlt)
	GUICtrlSetState($g_iStartBtnAlt, $GUI_SHOW)

	If $sMain = "" Then
		GUICtrlSetState($g_iStartBtnMain, $GUI_HIDE)
		_PlaceButtons($gc_iPopupWidth - $gc_iPad, $iTop, $g_iStartBtnAlt)
	Else
		GUICtrlSetData($g_iStartBtnMain, $sMain)
		GUICtrlSetState($g_iStartBtnMain, $GUI_SHOW)
		_PlaceButtons($gc_iPopupWidth - $gc_iPad, $iTop, $g_iStartBtnMain, $g_iStartBtnAlt)
	EndIf

	_UpdateHover($g_hStart, True) ; набор кнопок сменился, старое наведение забываем
EndFunc   ;==>_StartButtons


; Показать итог и закрыть окно. Все выходы из сценария до обновления выглядят
; одинаково: строка сверху, пояснение снизу и пауза, чтобы человек успел прочесть.
; Возвращает пустую строку, чтобы вызывающий писал 'Return _StartDone(...)'.
Func _StartDone($sLog, $sTitle, $sSub, $iWait = 2200, $iColor = $gc_iClrWarn)
	If $sLog <> "" Then _Util_Log($sLog)

	_StartState($sTitle, $sSub, $iColor)
	_Wait($iWait, $g_hStart)
	Return _StartClose()
EndFunc   ;==>_StartDone


; Ждёт ответа. 1 - главная кнопка, 2 - отказ или крестик.
Func _StartWait()
	$g_iChoice = 0
	$g_bCancel = False
	While $g_iChoice = 0 And Not $g_bCancel
		Sleep(30)
		_UpdateHover($g_hStart)
	WEnd

	Return $g_bCancel ? 2 : $g_iChoice
EndFunc   ;==>_StartWait


; Ставит состояние списка и ждёт ответа
Func _StartAsk($sMode)
	_StartMode($sMode)
	Return _StartWait()
EndFunc   ;==>_StartAsk


; Закрывает окно и отдаёт готовый ответ дальше по сценарию
Func _StartClose($vResult = "")
	If $g_hStart = 0 Then Return $vResult

	GUIRegisterMsg($WM_MOUSEWHEEL, "")
	_HotBtnForget($g_iStartBtnMain, $g_iStartBtnAlt)
	GUIDelete($g_hStart)

	$g_hStart = 0
	$g_iStartBtnMain = 0
	$g_iStartBtnAlt = 0
	$g_iStartTrack = 0
	$g_iStartThumb = 0

	ReDim $g_aStartIcon[0]
	ReDim $g_aStartName[0]
	ReDim $g_aStartPath[0]
	_UpdateHover(0, True)

	Return $vResult
EndFunc   ;==>_StartClose


; Колесо мыши приходит окну под курсором, а не контролу - крутим список сами
Func _OnStartWheel($hWnd, $iMsg, $wParam, $lParam)
	#forceref $iMsg, $lParam
	If $hWnd <> $g_hStart Then Return $GUI_RUNDEFMSG

	; HIWORD wParam - знаковый шаг колеса, вверх положительный
	Local $iDelta = BitAND(BitShift($wParam, 16), 0xFFFF)
	If $iDelta > 0x7FFF Then $iDelta -= 0x10000

	_StartScroll(($iDelta > 0) ? -1 : 1)
	Return $GUI_RUNDEFMSG
EndFunc   ;==>_OnStartWheel


; Клик по треку листает на страницу в сторону курсора - как обычная полоса прокрутки
Func _OnEvent_StartTrack()
	Local $aThumb = ControlGetPos($g_hStart, "", $g_iStartThumb)
	Local $aCursor = GUIGetCursorInfo($g_hStart)
	If Not IsArray($aThumb) Or Not IsArray($aCursor) Then Return

	_StartScroll(($aCursor[1] < $aThumb[1]) ? -$g_iStartSlots : $g_iStartSlots)
EndFunc   ;==>_OnEvent_StartTrack


; Колбэк разблокировки: список тает на глазах - это и есть весь индикатор
; хода работы, отдельная полоса прогресса тут не нужна.
Func _OnStartLeft($aLeft)
	If $g_hStart = 0 Then Return

	_StartSetRows(_FolderRows($aLeft))
	_StartSub("Осталось процессов: " & UBound($aLeft))
EndFunc   ;==>_OnStartLeft


; Колбэк отмены: заодно единственное место, где окно оживает во время
; разблокировки - подсветка кнопки под курсором держится на нём
Func _StartAborted()
	_UpdateHover($g_hStart)
	Return $g_bCancel
EndFunc   ;==>_StartAborted


; Согласие на обновление вместе с уверенностью, что папку отдадут.
; False - обновление не начинаем.
;
; Спрашивать раньше, чем стало ясно с папкой, нельзя: человек ждёт загрузку
; трёхсот мегабайт, а отказ вылезает уже посреди работы - именно так и случилось
; 26.08.26. Занятость проверяем не только списком процессов, но и пробным
; переименованием: держат папку и те, чей exe лежит снаружи.
Func _AskAndFreeFolder()
	Local $aBusy = _FolderHolders($g_sTargetPath)
	If UBound($aBusy) = 0 And _FolderIsFree($g_sTargetPath) Then
		If _StartAskVersion() <> 2 Then Return True
		_Util_Log("Пользователь отказался от обновления")
		Return False
	EndIf

	; Папку держат, а держателя не видно: закрывать нечего, предложить нечего
	If UBound($aBusy) = 0 Then
		_Util_Log("ОТКАЗ: папку удерживает неопознанная программа")
		_StartState($gc_sStartLocked, "Её удерживает программа, которую не видно", $gc_iClrWarn)
		_Wait(2600, $g_hStart)
		Return False
	EndIf

	_Util_Log("Папка занята процессами " & _FolderNames($aBusy))
	_StartHolders(_FolderRows($aBusy))

	While 1
		If _StartAsk("ask") = 2 Then
			_Util_Log("Пользователь отказался закрывать программы")
			Return False
		EndIf

		_StartMode("closing")
		If _FolderRelease($g_sTargetPath, "_OnStartLeft", "_StartAborted") Then
			_Util_Log("Папка освобождена, обновление продолжается")
			Return True
		EndIf

		If $g_bCancel Then
			_Util_Log("Разблокировка отменена")
			Return False
		EndIf

		; Не поддалось - предлагаем повторить: за это время может отпустить
		; тот, кто держал файл на секунду дольше остальных
		_Util_Log("Освободить папку не удалось, осталось " & UBound($g_aStartRows) & " строк")
		If _StartAsk("fail") = 2 Then Return False
	WEnd
EndFunc   ;==>_AskAndFreeFolder
