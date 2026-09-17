#include-once
#include <AutoItConstants.au3>
#include <Crypt.au3>
#include <FileConstants.au3>
#include <ProcessConstants.au3>
#include <WinAPI.au3>
#include <WinAPIProc.au3>

#include "Util.au3"

; ============================================================
; Архив: сверка SHA-256 и распаковка через 7-Zip CLI. GUI не знает,
; о ходе работы сообщает колбэками.
; ============================================================

Global Const $gc_iHashChunk = 1048576 ; байт за чтение: на 150 МБ это 150 тиков прогресса


; Сверяет SHA-256 файла, пустой хеш - проверять нечего. Блоками, а не _Crypt_HashFile:
; тот молчит на 150 МБ несколько секунд, и окно всё это время не отвечает.
; $sProgressCallback($iDone, $iTotal) - на каждом блоке, $sAbortCallback() - True прерывает.
; @error: 1 - файл не открылся, 2 - прервано, 3 - хеш не посчитался.
Func _Arc_VerifySha256($sFile, $sExpectedHash, $sProgressCallback = "", $sAbortCallback = "")
	If $sExpectedHash = "" Then Return True

	Local $hFile = FileOpen($sFile, $FO_BINARY)
	If $hFile = -1 Then Return SetError(1, 0, False)

	Local $iTotal = FileGetSize($sFile), $iDone = 0
	Local $hHash = 0, $bResult = 0

	_Crypt_Startup()
	While 1
		Local $bChunk = FileRead($hFile, $gc_iHashChunk)
		If @error Then ; конец файла: финальный вызов закрывает объект хеша
			$bResult = _Crypt_HashData($bChunk, $CALG_SHA_256, True, $hHash)
			ExitLoop
		EndIf

		$hHash = _Crypt_HashData($bChunk, $CALG_SHA_256, False, $hHash)
		If @error Then ExitLoop

		$iDone += $gc_iHashChunk
		If $sProgressCallback <> "" Then Call($sProgressCallback, ($iDone > $iTotal) ? $iTotal : $iDone, $iTotal)
		If $sAbortCallback <> "" And Call($sAbortCallback) Then
			; объект хеша закрывает только финальный _Crypt_HashData, до него не дошли
			DllCall("advapi32.dll", "bool", "CryptDestroyHash", "handle", $hHash)
			FileClose($hFile)
			_Crypt_Shutdown()
			Return SetError(2, 0, False)
		EndIf
	WEnd
	Local $iErr = @error
	_Crypt_Shutdown()
	FileClose($hFile)

	If $iErr Or Not IsBinary($bResult) Then Return SetError(3, 0, False)

	; _Crypt_HashData отдаёт binary вида 0x59D3..., отрезаем префикс
	Return StringLower(StringTrimLeft(String($bResult), 2)) = StringLower($sExpectedHash)
EndFunc   ;==>_Arc_VerifySha256


; Размер распакованного содержимого из итоговой строки листинга, 0 - не разобрать.
; Опираемся на форму строки, а не на слово 'files': оно зависит от локали сборки 7-Zip.
Func _Arc_UnpackedSize($s7zExe, $sArchive)
	Local $iPid = Run('"' & $s7zExe & '" l "' & $sArchive & '"', @TempDir, @SW_HIDE, $STDOUT_CHILD)
	If @error Then Return 0

	Local $sOut = ""
	While 1
		Local $sChunk = StdoutRead($iPid)
		If @error Then ExitLoop
		$sOut &= $sChunk
	WEnd

	; Итог - после последней строки из дефисов (к ней ведёт жадная точка):
	; '2026-08-24 09:30:23        20806        7701  3 files, 1 folders'
	Local $aTail = StringRegExp($sOut, '(?s)^.*[\r\n]-{10,}[^\r\n]*[\r\n]+(.*)$', 1)
	If Not @error Then
		; без отметки времени первое число - полный размер, иначе за размер примут её цифры
		Local $sTail = StringRegExpReplace($aTail[0], '\d{4}-\d\d-\d\d\s+\d\d:\d\d:\d\d', '')
		Local $aTotal = StringRegExp($sTail, '(\d+)\s+(\d+)\s+(\d+)', 1)
		If Not @error Then Return Int($aTotal[0])
	EndIf

	; Запасной разбор для сборок, где итоговая строка выглядит иначе
	Local $aFiles = StringRegExp($sOut, '(\d+)\s+\d+\s+\d+ files', 3)
	If @error Then Return 0
	Return Int($aFiles[UBound($aFiles) - 1])
EndFunc   ;==>_Arc_UnpackedSize


; Распаковывает архив в $sTargetDir. Прогресс - по росту папки: -bsp1 пишет в консоль,
; а при скрытом запуске в перенаправленный поток не попадает ни байта.
; $sProgressCallback($iDone, $iExpected) - примерно раз в 200 мс, $sAbortCallback() - True прерывает.
; @error: 1 - процесс не запустился, 2 - прервано, 3 - ошибка 7-Zip.
; Возвращает [распакованные байты, секунды].
Func _Arc_Unpack($s7zExe, $sArchive, $sTargetDir, $sProgressCallback = "", $sAbortCallback = "")
	If Not FileExists($s7zExe) Then Return SetError(1, 0, 0)
	DirCreate($sTargetDir)

	; Размер до распаковки: в папке уже может что-то лежать, и рост считаем от него
	Local $iBefore = DirGetSize($sTargetDir)
	If $iBefore < 0 Then $iBefore = 0
	Local $iExpected = _Arc_UnpackedSize($s7zExe, $sArchive)

	Local $sCmd = '"' & $s7zExe & '" x "' & $sArchive & '" -o"' & $sTargetDir & '" -y'
	Local $iPid = Run($sCmd, $sTargetDir, @SW_HIDE)
	If @error Then Return SetError(1, 0, 0)

	; handle держим ради кода возврата после выхода процесса
	Local $hProcess = _WinAPI_OpenProcess($PROCESS_QUERY_INFORMATION, False, $iPid)
	Local $iTimer = TimerInit()

	While ProcessExists($iPid)
		If $sAbortCallback <> "" And Call($sAbortCallback) Then
			ProcessClose($iPid)
			If $hProcess Then _WinAPI_CloseHandle($hProcess)
			Return SetError(2, 0, 0)
		EndIf

		If $iExpected > 0 And $sProgressCallback <> "" Then
			Local $iNow = DirGetSize($sTargetDir) - $iBefore ; обход дерева стоит около 12 мс
			Call($sProgressCallback, ($iNow > 0) ? $iNow : 0, $iExpected)
		EndIf
		Sleep(200)
	WEnd

	Local $iExit = _Util_ExitCode($hProcess)
	If $iExit <> 0 Then Return SetError(3, $iExit, 0)

	; отчитываемся фактическим приростом папки, а не тем, что обещал листинг
	Local $iGrown = DirGetSize($sTargetDir) - $iBefore
	If $iGrown <= 0 Then $iGrown = $iExpected

	Local $aResult[2] = [$iGrown, TimerDiff($iTimer) / 1000]
	Return $aResult
EndFunc   ;==>_Arc_Unpack
