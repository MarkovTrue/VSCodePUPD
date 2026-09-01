#include-once
#include <AutoItConstants.au3>
#include <FileConstants.au3>
#include <ProcessConstants.au3>
#include <WinAPI.au3>
#include <WinAPIMem.au3>
#include <WinAPIProc.au3>

#include "Common.au3"

; ============================================================
; Утилиты, общие для всех модулей: пути, процессы, занятость папки, свободное
; место, журнал работы. Ничего не знают ни про GUI, ни про сценарий обновления:
; о ходе работы сообщают колбэками, отмену спрашивают через них же.
; ============================================================

Global Const $gc_iLogLimit = 262144 ; байт: больше держать незачем, старый файл уходит в .bak

Global $g_sLogFile = "" ; пустой - журнал выключен


; Родительский каталог. Обратный слэш в строках AutoIt не экранируется,
; поэтому регулярка идёт в одинарных кавычках.
Func _Util_ParentDir($sPath)
	Return StringRegExpReplace(StringRegExpReplace($sPath, '\\+$', ''), '\\[^\\]+$', '')
EndFunc   ;==>_Util_ParentDir


Func _Util_FileName($sPathFile)
	Return StringRegExpReplace($sPathFile, '^.*[\\/]', '')
EndFunc   ;==>_Util_FileName


; Лежит ли $sPath внутри $sRoot
Func _Util_IsInsidePath($sPath, $sRoot)
	If $sRoot = "" Or $sPath = "" Then Return False
	Return StringInStr(StringLower($sPath) & "\", StringLower($sRoot) & "\") = 1
EndFunc   ;==>_Util_IsInsidePath


; Код возврата уже завершившегося процесса по его handle. Handle закрывается здесь.
; ProcessWaitClose и @extended после цикла ожидания отдают мусор, поэтому только так.
Func _Util_ExitCode($hProcess)
	If Not $hProcess Then Return 0

	Local $iExit = _WinAPI_GetExitCodeProcess($hProcess)
	If @error Then $iExit = 0
	_WinAPI_CloseHandle($hProcess)
	Return $iExit
EndFunc   ;==>_Util_ExitCode


; Размер файла, в который прямо сейчас пишет другой процесс. FileGetSize берёт
; размер из записи каталога, а NTFS обновляет её лениво - на растущем файле
; он отстаёт на несколько секунд или показывает ноль. Handle отдаёт правду.
Func _Util_FileSizeLive($sPath)
	If Not FileExists($sPath) Then Return 0

	Local $hFile = _WinAPI_CreateFileEx($sPath, $OPEN_EXISTING, $GENERIC_READ, _
			BitOR($FILE_SHARE_READ, $FILE_SHARE_WRITE, $FILE_SHARE_DELETE))
	If @error Then Return FileGetSize($sPath)

	Local $iSize = _WinAPI_GetFileSizeEx($hFile)
	_WinAPI_CloseHandle($hFile)
	Return $iSize
EndFunc   ;==>_Util_FileSizeLive


; Свободно на томе, которому принадлежит путь. -1 - определить не удалось
; (сетевой путь, тома нет). Байты, а не мегабайты, как отдаёт DriveSpaceFree.
Func _Util_FreeSpace($sPath)
	Local $sRoot = StringRegExpReplace($sPath, '^(\\\\[^\\]+\\[^\\]+|[A-Za-z]:).*$', '$1') & "\"

	Local $nFreeMb = DriveSpaceFree($sRoot)
	If @error Or $nFreeMb <= 0 Then Return -1
	Return $nFreeMb * 1048576
EndFunc   ;==>_Util_FreeSpace


; Включает журнал. Файл рядом с программой: разбираться после сбоя больше не по чему.
; Папка только для чтения (диск, сетевой ресурс) - журнал просто не ведётся.
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

; Отдадут ли папку прямо сейчас. Ответ даёт то же действие, которым папка потом
; забирается: переименование внутри тома мгновенно и проверяет всё дерево сразу -
; открытый внутри файл и чужой рабочий каталог одинаково его заваливают.
; Список процессов такой уверенности не даёт: держателя видно только по exe,
; а держат папку и те, чей exe лежит снаружи.
;
; Проба помечается в ini теми же ключами, что и снос старой версии: оборвись
; питание между двумя переименованиями - имя вернёт _RecoverRenamed при следующем
; запуске. Метки снимаем только после удачного возврата.
Func _FolderIsFree($sFolder)
	If Not FileExists($sFolder) Then Return False

	Local $sProbe = $sFolder & " ~check"
	For $i = 2 To 20
		If Not FileExists($sProbe) Then ExitLoop
		$sProbe = $sFolder & " ~check" & $i
	Next

	IniWrite($gc_sIniFile, "State", "RenamedPath", $sProbe)
	IniWrite($gc_sIniFile, "State", "RenamedFrom", $sFolder)

	If Not _FolderRename($sFolder, $sProbe) Then
		IniDelete($gc_sIniFile, "State", "RenamedPath")
		IniDelete($gc_sIniFile, "State", "RenamedFrom")
		Return False
	EndIf

	If Not _FolderRename($sProbe, $sFolder) Then
		_Util_Log("ОШИБКА: проба переименования не вернулась, папка осталась '" & $sProbe & "'")
		Return False ; метки в ini оставляем: имя вернёт _RecoverRenamed
	EndIf

	IniDelete($gc_sIniFile, "State", "RenamedPath")
	IniDelete($gc_sIniFile, "State", "RenamedFrom")
	Return True
EndFunc   ;==>_FolderIsFree


; Переименование каталога одним системным вызовом. DirMove здесь не годится:
; он идёт через SHFileOperation, а тот на занятой папке целую секунду перебирает
; повторы и в принципе умеет откатываться на перенос по одному файлу - на пробе
; это лишний риск растащить папку. MoveFile либо переименовывает целиком, либо
; сразу отказывает, и на отказ уходит меньше миллисекунды.
Func _FolderRename($sFrom, $sTo)
	Local $aCall = DllCall("kernel32.dll", "bool", "MoveFileW", "wstr", $sFrom, "wstr", $sTo)
	Return Not @error And $aCall[0]
EndFunc   ;==>_FolderRename


; Процессы, которые держат папку: [[PID, имя, путь к exe, папка-причина]].
; Держат её не только те, чей exe лежит внутри (Code.exe и node из расширений),
; но и те, у кого внутри рабочий каталог - терминал, git, языковой сервер.
; У последних exe лежит в System32 или в профиле, и по одному имени файла их
; не отличить от посторонних.
;
; Папку-причину показываем в таблице: по ней видно, за что процесс попал в список,
; а путь к exe нужен, чтобы взять оттуда иконку.
Func _FolderHolders($sFolder)
	Local $aBusy[0][4]
	Local $aList = ProcessList()
	If @error Then Return $aBusy

	For $i = 1 To $aList[0][0]
		If $aList[$i][1] = @AutoItPID Then ContinueLoop ; себя закрывать незачем

		Local $sExe = _ProcessPath($aList[$i][1])
		Local $sWhere = ""

		If _Util_IsInsidePath($sExe, $sFolder) Then
			$sWhere = _Util_ParentDir($sExe)
		Else
			; Рабочий каталог читаем только у тех, кто не попался по exe: чтение PEB
			; дороже, а для запущенных изнутри папки оно уже ничего не изменит
			Local $sCwd = _ProcessCwd($aList[$i][1])
			If Not _Util_IsInsidePath($sCwd, $sFolder) Then ContinueLoop
			$sWhere = $sCwd
		EndIf

		ReDim $aBusy[UBound($aBusy) + 1][4]
		$aBusy[UBound($aBusy) - 1][0] = $aList[$i][1]
		$aBusy[UBound($aBusy) - 1][1] = $aList[$i][0]
		$aBusy[UBound($aBusy) - 1][2] = $sExe
		$aBusy[UBound($aBusy) - 1][3] = $sWhere
	Next

	Return $aBusy
EndFunc   ;==>_FolderHolders


; Строки таблицы: [[имя, папка, путь к exe, сколько процессов]]. Одна строка на
; процесс - это шум: у запущенного VS Code их бывает и десяток с одним именем
; и одной папкой. Схлопываем по паре 'имя + папка', повторы показываем счётчиком.
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

		ReDim $aRows[UBound($aRows) + 1][4]
		$aRows[UBound($aRows) - 1][0] = $aBusy[$i][1]
		$aRows[UBound($aRows) - 1][1] = $aBusy[$i][3]
		$aRows[UBound($aRows) - 1][2] = _ProcessIcon($aBusy[$i][2])
		$aRows[UBound($aRows) - 1][3] = 1
	Next

	Return $aRows
EndFunc   ;==>_FolderRows


; Файл, из которого брать иконку строки. Пустая строка - брать неоткуда:
; у консольных утилит (bash, git, pet) ресурса с иконкой нет, и столбец
; остался бы дырявым. ExtractIconEx с индексом -1 отвечает, сколько их в файле.
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


; Имена держателей для показа: одно имя на процесс, дальше третьего не перечисляем -
; в подстрочник маленького окна больше не влезает.
Func _FolderNames($aBusy)
	Local $sNames = "", $iCount = 0

	For $i = 0 To UBound($aBusy) - 1
		If StringInStr($sNames, $aBusy[$i][1]) Then ContinueLoop

		$sNames &= ($sNames = "") ? $aBusy[$i][1] : ", " & $aBusy[$i][1]
		$iCount += 1
		If $iCount >= 3 And $i < UBound($aBusy) - 1 Then Return $sNames & " и другие процессы"
	Next

	Return $sNames
EndFunc   ;==>_FolderNames


; Снимает всех держателей папки и ждёт, пока она освободится. True - папку отдали.
;
; Закрываем сразу и насмерть, без вежливого WM_CLOSE: кнопка 'Разблокировать и
; обновить' - это уже решение, а вопрос редактора о несохранённом остановил бы
; всё на середине и ничего бы не разблокировал.
;
; $sOnLeft получает список ещё живых держателей на каждом круге, $sIsAborted
; спрашивают там же: про окно этот модуль ничего не знает.
Func _FolderRelease($sFolder, $sOnLeft = "", $sIsAborted = "", $iTimeout = 20000)
	_Util_Log("Освобождение папки: " & _FolderCloseAll($sFolder) & " процессов")

	; Ждём не исчезновения процессов, а самой папки: закрытый редактор оставляет
	; за собой хвосты, и наоборот - список может опустеть раньше, чем отпустят файлы
	Local $iTimer = TimerInit(), $iNextCheck = 0
	While TimerDiff($iTimer) < $iTimeout
		Sleep(30)
		If $sIsAborted <> "" And Call($sIsAborted) Then Return False

		; Проба стоит меньше миллисекунды, но дёргать её тридцать раз в секунду незачем
		If TimerDiff($iTimer) < $iNextCheck Then ContinueLoop
		$iNextCheck = TimerDiff($iTimer) + 400

		If $sOnLeft <> "" Then Call($sOnLeft, _FolderHolders($sFolder))
		If _FolderIsFree($sFolder) Then Return True

		; Снимаем каждый круг, а не один раз: у гибнущего редактора всё это время
		; рождаются новые дочерние процессы, и они держат папку не хуже
		_FolderCloseAll($sFolder)
	WEnd

	Return False
EndFunc   ;==>_FolderRelease


; Снимает всех держателей папки, возвращает их число
Func _FolderCloseAll($sFolder)
	Local $aBusy = _FolderHolders($sFolder)

	For $i = 0 To UBound($aBusy) - 1
		ProcessClose($aBusy[$i][0])
	Next

	Return UBound($aBusy)
EndFunc   ;==>_FolderCloseAll


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


; Рабочий каталог процесса. Его не отдают ни ProcessList, ни WMI, ни любая другая
; готовая функция - читаем PEB чужого процесса: смещения x64 PEB+0x20 =
; ProcessParameters, +0x38 в нём = CurrentDirectory.DosPath (UNICODE_STRING).
; Любой отказ по дороге - пустая строка: процесс просто не попадёт в список
; держателей, точный ответ всё равно даёт _FolderIsFree.
Func _ProcessCwd($iPID)
	If Not @AutoItX64 Then Return "" ; смещения ниже верны только для 64-битной сборки

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

	; Рабочий каталог хранится со слэшем на конце, пути в программе - без него
	Return _CloseAnd($hProcess, StringRegExpReplace(DllStructGetData($tPath, 1), '\\+$', ''))
EndFunc   ;==>_ProcessCwd


; Закрыть handle и вернуть готовый результат: без неё каждый выход из _ProcessCwd
; занимал бы три строки, и забытый handle прятался бы среди них.
Func _CloseAnd($hProcess, $vResult)
	_WinAPI_CloseHandle($hProcess)
	Return $vResult
EndFunc   ;==>_CloseAnd
