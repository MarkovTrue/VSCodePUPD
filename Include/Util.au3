#include-once
#include <FileConstants.au3>
#include <ProcessConstants.au3>
#include <WinAPI.au3>
#include <WinAPIProc.au3>

; ============================================================
; Мелкие утилиты, общие для всех модулей: пути, код возврата процесса,
; журнал работы. Ничего не знают ни про GUI, ни про сценарий обновления.
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
