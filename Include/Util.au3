#include-once
#include <AutoItConstants.au3>
#include <FileConstants.au3>
#include <ProcessConstants.au3>
#include <WinAPI.au3>
#include <WinAPIMem.au3>
#include <WinAPIProc.au3>

#include "Common.au3"

; ============================================================
; Утилиты для всех модулей: пути, метки прерванного прогона, процессы, занятость
; папки, журнал. Про GUI и сценарий не знают: о ходе работы и отмене - колбэками.
; ============================================================

Global Const $gc_iLogLimit = 262144 ; байт, дальше старый журнал уходит в .bak

Global $g_sLogFile = "" ; пустой - журнал выключен


; Родительский каталог. Регулярки с путями - в одинарных кавычках: '\' в AutoIt не экранируется
Func _Util_ParentDir($sPath)
	Return StringRegExpReplace(StringRegExpReplace($sPath, '\\+$', ''), '\\[^\\]+$', '')
EndFunc   ;==>_Util_ParentDir


; Путь без пробелов по краям и слэша на конце: 'VS Code\' & ' 1.105' дало бы папку внутри VS Code
Func _Util_TrimPath($sPath)
	Return StringRegExpReplace(StringStripWS($sPath, 3), '\\+$', '')
EndFunc   ;==>_Util_TrimPath


Func _Util_FileName($sPathFile)
	Return StringRegExpReplace($sPathFile, '^.*[\\/]', '')
EndFunc   ;==>_Util_FileName


Func _Util_IsInsidePath($sPath, $sRoot)
	If $sRoot = "" Or $sPath = "" Then Return False
	Return StringInStr(StringLower($sPath) & "\", StringLower($sRoot) & "\") = 1
EndFunc   ;==>_Util_IsInsidePath


; Первое незанятое имя: '$sBase', '$sBase 2', '$sBase 3'... Чужие папки не трогаем
Func _Util_FreeName($sBase)
	Local $sName = $sBase
	For $i = 2 To 20
		If Not FileExists($sName) Then ExitLoop
		$sName = $sBase & " " & $i
	Next
	Return $sName
EndFunc   ;==>_Util_FreeName


; Метка прерванного прогона: пара ключей секции State, пишется до переноса и снимается после
Func _Util_MarkSet($sKey1, $sValue1, $sKey2, $sValue2)
	IniWrite($gc_sIniFile, "State", $sKey1, $sValue1)
	IniWrite($gc_sIniFile, "State", $sKey2, $sValue2)
EndFunc   ;==>_Util_MarkSet


Func _Util_MarkClear($sKey1, $sKey2)
	IniDelete($gc_sIniFile, "State", $sKey1)
	IniDelete($gc_sIniFile, "State", $sKey2)
EndFunc   ;==>_Util_MarkClear


; Код возврата завершившегося процесса, handle закрывается здесь.
; ProcessWaitClose и @extended после цикла ожидания отдают мусор.
Func _Util_ExitCode($hProcess)
	If Not $hProcess Then Return 0

	Local $iExit = _WinAPI_GetExitCodeProcess($hProcess)
	If @error Then $iExit = 0
	_WinAPI_CloseHandle($hProcess)
	Return $iExit
EndFunc   ;==>_Util_ExitCode


; Размер файла, в который пишет другой процесс. FileGetSize берёт его из записи
; каталога, а NTFS обновляет её лениво - на растущем файле там ноль или отставание.
Func _Util_FileSizeLive($sPath)
	If Not FileExists($sPath) Then Return 0

	Local $hFile = _WinAPI_CreateFileEx($sPath, $OPEN_EXISTING, $GENERIC_READ, _
			BitOR($FILE_SHARE_READ, $FILE_SHARE_WRITE, $FILE_SHARE_DELETE))
	If @error Then Return FileGetSize($sPath)

	Local $iSize = _WinAPI_GetFileSizeEx($hFile)
	_WinAPI_CloseHandle($hFile)
	Return $iSize
EndFunc   ;==>_Util_FileSizeLive


; Свободные байты на томе пути. -1 - не определить (сетевой путь, тома нет).
Func _Util_FreeSpace($sPath)
	Local $sRoot = StringRegExpReplace($sPath, '^(\\\\[^\\]+\\[^\\]+|[A-Za-z]:).*$', '$1') & "\"

	Local $nFreeMb = DriveSpaceFree($sRoot)
	If @error Or $nFreeMb <= 0 Then Return -1
	Return $nFreeMb * 1048576
EndFunc   ;==>_Util_FreeSpace


; Журнал рядом с программой: разбираться после сбоя больше не по чему.
; Папка только для чтения - журнал просто не ведётся.
Func _Util_LogStart($sFile, $sHeader = "")
	If FileGetSize($sFile) > $gc_iLogLimit Then
		FileDelete($sFile & ".bak")
		FileMove($sFile, $sFile & ".bak")
	EndIf

	Local $hFile = FileOpen($sFile, BitOR($FO_APPEND, $FO_UTF8))
	If $hFile = -1 Then Return SetError(1, 0, False)
	FileClose($hFile)

	$g_sLogFile = $sFile
	_Util_Log("=== " & $sHeader & " ===")
	Return True
EndFunc   ;==>_Util_LogStart


Func _Util_Log($sText)
	If $g_sLogFile = "" Then Return

	Local $hFile = FileOpen($g_sLogFile, BitOR($FO_APPEND, $FO_UTF8))
	If $hFile = -1 Then Return

	FileWriteLine($hFile, @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC & "  " & $sText)
	FileClose($hFile)
EndFunc   ;==>_Util_Log


; ============================================================
; Занятость папки
; ============================================================

; Отдадут ли папку сейчас. Точный ответ даёт только само переименование: его
; заваливают и открытый файл, и чужой рабочий каталог во всём дереве, а по списку
; процессов не видно тех, чей exe лежит снаружи.
; Проба помечена в ini как снос старой версии: оборвись питание между двумя
; переименованиями - имя вернёт _RecoverRenamed.
Func _FolderIsFree($sFolder)
	If Not FileExists($sFolder) Then Return False

	Local $sProbe = _Util_FreeName($sFolder & " ~check")
	_Util_MarkSet("RenamedPath", $sProbe, "RenamedFrom", $sFolder)

	If Not _FolderRename($sFolder, $sProbe) Then
		_Util_MarkClear("RenamedPath", "RenamedFrom")
		Return False
	EndIf

	If Not _FolderRename($sProbe, $sFolder) Then
		_Util_Log("ОШИБКА: проба переименования не вернулась, папка осталась '" & $sProbe & "'")
		Return False ; метка остаётся: имя вернёт _RecoverRenamed
	EndIf

	_Util_MarkClear("RenamedPath", "RenamedFrom")
	Return True
EndFunc   ;==>_FolderIsFree


; Переименование каталога одним системным вызовом: целиком или отказ, меньше миллисекунды.
; DirMove идёт через SHFileOperation - секунда повторов на отказ, а для пробы это лишнее.
Func _FolderRename($sFrom, $sTo)
	Local $aCall = DllCall("kernel32.dll", "bool", "MoveFileW", "wstr", $sFrom, "wstr", $sTo)
	Return Not @error And $aCall[0]
EndFunc   ;==>_FolderRename


; Процессы, которые держат папку: [[PID, имя, путь к exe, папка-причина]].
; Держат и те, чей exe внутри (Code.exe, node расширений), и те, у кого внутри
; рабочий каталог (терминал, git, языковой сервер) - их exe лежит снаружи.
; Папка-причина объясняет в таблице, за что процесс в списке, exe даёт иконку.
Func _FolderHolders($sFolder)
	Local $aBusy[0][4]
	Local $aList = ProcessList()
	If @error Then Return $aBusy

	For $i = 1 To $aList[0][0]
		If $aList[$i][1] = @AutoItPID Then ContinueLoop

		Local $sExe = _ProcessPath($aList[$i][1])
		Local $sWhere = ""

		If _Util_IsInsidePath($sExe, $sFolder) Then
			$sWhere = _Util_ParentDir($sExe)
		Else
			; PEB читаем только у тех, кто не попался по exe: это дороже
			Local $sCwd = _ProcessCwd($aList[$i][1])
			If Not _Util_IsInsidePath($sCwd, $sFolder) Then ContinueLoop
			$sWhere = $sCwd
		EndIf

		Local $iRow = UBound($aBusy)
		ReDim $aBusy[$iRow + 1][4]
		$aBusy[$iRow][0] = $aList[$i][1]
		$aBusy[$iRow][1] = $aList[$i][0]
		$aBusy[$iRow][2] = $sExe
		$aBusy[$iRow][3] = $sWhere
	Next

	Return $aBusy
EndFunc   ;==>_FolderHolders


; Строки таблицы: [[имя, папка, источник иконки, сколько процессов]]. У редактора
; бывает десяток процессов с одним именем и папкой - схлопываем их в счётчик.
Func _FolderRows($aBusy)
	Local $aRows[0][4]

	For $i = 0 To UBound($aBusy) - 1
		Local $iSame = -1
		For $j = 0 To UBound($aRows) - 1
			If $aRows[$j][0] = $aBusy[$i][1] And $aRows[$j][1] = $aBusy[$i][3] Then
				$iSame = $j
				ExitLoop
			EndIf
		Next

		If $iSame >= 0 Then
			$aRows[$iSame][3] += 1
			ContinueLoop
		EndIf

		Local $iRow = UBound($aRows)
		ReDim $aRows[$iRow + 1][4]
		$aRows[$iRow][0] = $aBusy[$i][1]
		$aRows[$iRow][1] = $aBusy[$i][3]
		$aRows[$iRow][2] = _ProcessIcon($aBusy[$i][2])
		$aRows[$iRow][3] = 1
	Next

	Return $aRows
EndFunc   ;==>_FolderRows


; Файл, из которого брать иконку строки, или '' - у консольных утилит (bash, git)
; иконки в exe нет. ExtractIconEx с индексом -1 отвечает, сколько их в файле.
Func _ProcessIcon($sExe)
	If $sExe = "" Then Return ""

	Local $aCall = DllCall("shell32.dll", "uint", "ExtractIconExW", _
			"wstr", $sExe, _
			"int", -1, _
			"ptr", 0, _
			"ptr", 0, _
			"uint", 1)
	If @error Or $aCall[0] = 0 Then Return ""

	Return $sExe
EndFunc   ;==>_ProcessIcon


; Имена держателей без повторов, не больше трёх: больше в подстрочник не влезает
Func _FolderNames($aBusy)
	Local $sNames = "", $iCount = 0

	For $i = 0 To UBound($aBusy) - 1
		Local $sName = $aBusy[$i][1]
		If StringInStr(", " & $sNames & ", ", ", " & $sName & ", ") Then ContinueLoop
		If $iCount = 3 Then Return $sNames & " и другие процессы"

		$sNames &= ($sNames = "") ? $sName : ", " & $sName
		$iCount += 1
	Next

	Return $sNames
EndFunc   ;==>_FolderNames


; Снимает держателей папки и ждёт, пока её отдадут. True - отдали.
; Насмерть, без WM_CLOSE: вопрос редактора о несохранённом остановил бы всё на середине.
; $sOnLeft получает живых держателей на каждом круге, $sIsAborted спрашивает об отмене.
Func _FolderRelease($sFolder, $sOnLeft = "", $sIsAborted = "", $iTimeout = 20000)
	Local $aBusy = _FolderHolders($sFolder)
	_Util_Log("Освобождение папки: " & UBound($aBusy) & " процессов")
	_FolderKillHolders($aBusy)

	; Ждём саму папку, а не пустой список: файлы отпускают не сразу после гибели процесса
	Local $iTimer = TimerInit(), $iNextCheck = 0
	While TimerDiff($iTimer) < $iTimeout
		Sleep(30)
		If $sIsAborted <> "" And Call($sIsAborted) Then Return False

		; Обход процессов стоит около 50 мс - не чаще раза в 400 мс
		If TimerDiff($iTimer) < $iNextCheck Then ContinueLoop
		$iNextCheck = TimerDiff($iTimer) + 400

		$aBusy = _FolderHolders($sFolder)
		If $sOnLeft <> "" Then Call($sOnLeft, $aBusy)
		If _FolderIsFree($sFolder) Then Return True

		; Каждый круг: у гибнущего редактора всё ещё рождаются дочерние процессы
		_FolderKillHolders($aBusy)
	WEnd

	Return False
EndFunc   ;==>_FolderRelease


Func _FolderKillHolders($aBusy)
	For $i = 0 To UBound($aBusy) - 1
		ProcessClose($aBusy[$i][0])
	Next
EndFunc   ;==>_FolderKillHolders


; Путь к exe процесса. QueryFullProcessImageName хватает ограниченного доступа - без прав администратора.
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


; Рабочий каталог процесса: его не отдают ни ProcessList, ни WMI, поэтому читаем PEB.
; Смещения x64: PEB+0x20 = ProcessParameters, +0x38 в нём = CurrentDirectory.DosPath.
; Любой отказ - пустая строка: точный ответ о занятости всё равно даёт _FolderIsFree.
Func _ProcessCwd($iPID)
	If Not @AutoItX64 Then Return "" ; смещения верны только для 64-битной сборки

	Local $aProcess = DllCall("kernel32.dll", "handle", "OpenProcess", _
			"dword", BitOR($PROCESS_QUERY_LIMITED_INFORMATION, $PROCESS_VM_READ), _
			"bool", False, _
			"dword", $iPID)
	If @error Or Not $aProcess[0] Then Return ""
	Local $hProcess = $aProcess[0]

	Local $tPBI = DllStructCreate("ptr ExitStatus; ptr Peb; ptr Affinity; ptr Priority; ptr Pid; ptr ParentPid")
	Local $aCall = DllCall("ntdll.dll", "int", "NtQueryInformationProcess", _
			"handle", $hProcess, _
			"int", 0, _ ; ProcessBasicInformation
			"struct*", $tPBI, _
			"ulong", DllStructGetSize($tPBI), _
			"ulong*", 0)
	If @error Or $aCall[0] <> 0 Then Return _CloseAnd($hProcess, "")

	Local $iRead = 0
	Local $tPtr = DllStructCreate("ptr")
	If Not _WinAPI_ReadProcessMemory($hProcess, DllStructGetData($tPBI, "Peb") + 0x20, $tPtr, 8, $iRead) Then _
			Return _CloseAnd($hProcess, "")

	; UNICODE_STRING: длина в байтах, ёмкость, выравнивание, указатель на строку
	Local $tStr = DllStructCreate("ushort Len; ushort Max; uint Align; ptr Buffer")
	If Not _WinAPI_ReadProcessMemory($hProcess, DllStructGetData($tPtr, 1) + 0x38, $tStr, 16, $iRead) Then _
			Return _CloseAnd($hProcess, "")

	Local $iLen = DllStructGetData($tStr, "Len")
	If $iLen = 0 Or $iLen > 8192 Then Return _CloseAnd($hProcess, "")

	Local $tPath = DllStructCreate("wchar[" & Int($iLen / 2) & "]")
	If Not _WinAPI_ReadProcessMemory($hProcess, DllStructGetData($tStr, "Buffer"), $tPath, $iLen, $iRead) Then _
			Return _CloseAnd($hProcess, "")

	; Рабочий каталог хранится со слэшем на конце
	Return _CloseAnd($hProcess, _Util_TrimPath(DllStructGetData($tPath, 1)))
EndFunc   ;==>_ProcessCwd


; Закрыть handle и вернуть результат: каждый выход из _ProcessCwd - одна строка, handle не теряется
Func _CloseAnd($hProcess, $vResult)
	_WinAPI_CloseHandle($hProcess)
	Return $vResult
EndFunc   ;==>_CloseAnd
