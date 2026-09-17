#include-once
#include <AutoItConstants.au3>
#include <FileConstants.au3>
#include <InetConstants.au3>
#include <WinAPI.au3>
#include <ProcessConstants.au3>
#include <WinAPIFiles.au3>
#include <WinAPIProc.au3>

#include "Util.au3"

; ============================================================
; Загрузка: опрос update API и скачивание архива. GUI не знает,
; о ходе работы сообщает колбэками вызывающей стороны.
; ============================================================

Global Const $gc_iNetRetryCount = 5      ; столько обрывов curl переживает сам
Global Const $gc_iNetConnectTimeout = 15 ; с, ожидание соединения

; Откуда можно качать. Хеш приходит в том же ответе, что и ссылка: SHA-256
; подтверждает целостность, но не источник - хост проверяем отдельно.
Global Const $gc_sTrustedHosts = "|microsoft.com|vo.msecnd.net|visualstudio.com|azureedge.net|windows.net|"


; Спрашивает update API: [версия, ссылка на архив, sha256, дата выпуска в unix-мс].
; $sTickCallback вызывается в паузах ожидания.
; @error: 1 - ответа нет, 2 - ответ не разобран, 4 - ссылка ведёт на чужой хост.
Func _Net_CheckUpdate($sApiUrl, $iTimeout, $sTickCallback = "")
	; имя с PID: два экземпляра не должны читать чужой ответ
	Local $sTmp = @TempDir & "\vscodepupd_update_" & @AutoItPID & ".json"
	FileDelete($sTmp)

	Local $hDownload = InetGet($sApiUrl, $sTmp, $INET_FORCERELOAD, $INET_DOWNLOADBACKGROUND)
	If @error Then Return SetError(1, 0, 0) ; иначе ждали бы таймаут на мёртвом handle
	Local $iTimer = TimerInit()

	While Not InetGetInfo($hDownload, $INET_DOWNLOADCOMPLETE)
		If TimerDiff($iTimer) > $iTimeout Then
			InetClose($hDownload)
			Return SetError(1, 0, 0)
		EndIf
		Sleep(30)
		If $sTickCallback <> "" Then Call($sTickCallback)
	WEnd

	Local $bOk = Not InetGetInfo($hDownload, $INET_DOWNLOADERROR)
	InetClose($hDownload)
	If Not $bOk Then Return SetError(1, 0, 0)

	Local $sJson = FileRead($sTmp)
	FileDelete($sTmp)

	Local $aVer = StringRegExp($sJson, '"productVersion"\s*:\s*"([^"]+)"', 1)
	If @error Then Return SetError(2, 0, 0)
	Local $aUrl = StringRegExp($sJson, '"url"\s*:\s*"([^"]+)"', 1)
	If @error Then Return SetError(2, 0, 0)
	If Not _Net_IsTrustedUrl($aUrl[0]) Then Return SetError(4, 0, 0)

	Local $aHash = StringRegExp($sJson, '"sha256hash"\s*:\s*"([^"]+)"', 1)
	Local $sHash = @error ? "" : $aHash[0]

	Local $aStamp = StringRegExp($sJson, '"timestamp"\s*:\s*(\d+)', 1)
	Local $iStamp = @error ? 0 : Number($aStamp[0])

	Local $aResult[4] = [$aVer[0], $aUrl[0], $sHash, $iStamp]
	Return $aResult
EndFunc   ;==>_Net_CheckUpdate


; Только HTTPS и только хосты Microsoft: по ссылке качается исполняемый код
Func _Net_IsTrustedUrl($sUrl)
	Local $aHost = StringRegExp($sUrl, '^https://([^/:]+)', 1)
	If @error Then Return False

	Local $sHost = StringLower($aHost[0])
	For $sDomain In StringSplit(StringTrimLeft(StringTrimRight($gc_sTrustedHosts, 1), 1), "|", 2)
		If $sHost = $sDomain Or StringRight($sHost, StringLen($sDomain) + 1) = "." & $sDomain Then Return True
	Next

	Return False
EndFunc   ;==>_Net_IsTrustedUrl


; Размер файла на сервере, 0 - не узнать. Через curl с таймаутом: InetGetSize
; блокирует поток без предела, пока на экране окно проверки.
Func _Net_GetRemoteSize($sUrl, $iTimeout = 5000, $sTickCallback = "")
	Local $sCurl = @SystemDir & "\curl.exe"
	If Not FileExists($sCurl) Then Return 0

	Local $iSeconds = Int($iTimeout / 1000)
	If $iSeconds < 2 Then $iSeconds = 2

	Local $iPid = Run('"' & $sCurl & '" -sIL --max-time ' & $iSeconds & _
			' --connect-timeout ' & $iSeconds & ' "' & $sUrl & '"', @TempDir, @SW_HIDE, $STDOUT_CHILD)
	If @error Then Return 0

	Local $sOut = "", $iTimer = TimerInit()
	While ProcessExists($iPid)
		$sOut &= StdoutRead($iPid)
		If TimerDiff($iTimer) > $iTimeout + 1000 Then
			ProcessClose($iPid)
			Return 0
		EndIf
		Sleep(30)
		If $sTickCallback <> "" Then Call($sTickCallback)
	WEnd
	$sOut &= StdoutRead($iPid)

	; При -L ответов несколько: Content-Length берём только у последнего, у редиректа он свой
	$sOut = StringRegExpReplace($sOut, '(?s)^.*(?=\nHTTP/)', '')
	Local $aLen = StringRegExp($sOut, '(?im)^Content-Length:\s*(\d+)', 1)
	If @error Then Return 0
	Return Int($aLen[0])
EndFunc   ;==>_Net_GetRemoteSize


; Качает $sUrl в $sFile через curl.exe из System32: докачка (-C -) и повторы при обрывах.
; Прогресс - по размеру файла на диске, stdout не читаем.
; $sProgressCallback($iDone, $nSpeed) - примерно раз в 120 мс.
; $sAbortCallback() - True прерывает загрузку.
; @error: 1 - процесс не запустился, 2 - прервано, 3 - ошибка curl (@extended - код).
; Возвращает секунды загрузки, 0 - файл уже лежал целиком.
Func _Net_Download($sUrl, $sFile, $iTotalSize, $sProgressCallback = "", $sAbortCallback = "")
	Local $sCurl = @SystemDir & "\curl.exe"
	If Not FileExists($sCurl) Then Return _Net_DownloadInet($sUrl, $sFile, $sProgressCallback, $sAbortCallback)

	Local $iAlready = _Util_FileSizeLive($sFile)
	If $iAlready > 0 And $iTotalSize > 0 And $iAlready >= $iTotalSize Then Return 0

	Local $sCmd = '"' & $sCurl & '" -L -C - --retry ' & $gc_iNetRetryCount & ' --retry-delay 2 --retry-all-errors' & _
			' --connect-timeout ' & $gc_iNetConnectTimeout & ' --no-progress-meter -o "' & $sFile & '" "' & $sUrl & '"'

	Local $iPid = Run($sCmd, _Util_ParentDir($sFile), @SW_HIDE)
	If @error Then Return SetError(1, 0, 0)

	Local $iSpeedTimer = TimerInit(), $iTotalTimer = TimerInit()
	Local $iLastSize = $iAlready, $nSpeed = 0

	; Handle держит запись о процессе живой: код возврата читается и после выхода
	Local $hProcess = _WinAPI_OpenProcess($PROCESS_QUERY_INFORMATION, False, $iPid)

	While ProcessExists($iPid)
		If $sAbortCallback <> "" And Call($sAbortCallback) Then
			ProcessClose($iPid)
			If $hProcess Then _WinAPI_CloseHandle($hProcess)
			Return SetError(2, 0, 0)
		EndIf

		Local $iNow = _Util_FileSizeLive($sFile)
		Local $nElapsed = TimerDiff($iSpeedTimer)
		If $nElapsed >= 700 Then
			; сглаживаем: мгновенная скорость скачет на каждом чтении буфера
			Local $nInstant = ($iNow - $iLastSize) / ($nElapsed / 1000)
			$nSpeed = ($nSpeed = 0) ? $nInstant : ($nSpeed * 0.6 + $nInstant * 0.4)
			$iLastSize = $iNow
			$iSpeedTimer = TimerInit()
		EndIf
		If $sProgressCallback <> "" Then Call($sProgressCallback, $iNow, $nSpeed)
		Sleep(120)
	WEnd

	Local $iExit = _Util_ExitCode($hProcess)
	; 2 - незнакомый ключ: curl 7.55 ранних сборок Windows 10 не знает --retry-all-errors
	; и --no-progress-meter, а файл он при этом не трогает
	If $iExit = 2 Then Return _Net_DownloadInet($sUrl, $sFile, $sProgressCallback, $sAbortCallback)
	If $iExit <> 0 Then Return SetError(3, $iExit, 0)

	Return TimerDiff($iTotalTimer) / 1000
EndFunc   ;==>_Net_Download


; Запасной путь без curl: InetGet качает в фоне, но без докачки - файл начинается заново
Func _Net_DownloadInet($sUrl, $sFile, $sProgressCallback = "", $sAbortCallback = "")
	FileDelete($sFile)

	Local $hDownload = InetGet($sUrl, $sFile, $INET_FORCERELOAD, $INET_DOWNLOADBACKGROUND)
	If @error Then Return SetError(1, 0, 0)
	Local $iSpeedTimer = TimerInit(), $iTotalTimer = TimerInit()
	Local $iLastSize = 0, $nSpeed = 0

	While Not InetGetInfo($hDownload, $INET_DOWNLOADCOMPLETE)
		Sleep(120)
		If $sAbortCallback <> "" And Call($sAbortCallback) Then
			InetClose($hDownload)
			Return SetError(2, 0, 0)
		EndIf

		Local $iNow = InetGetInfo($hDownload, $INET_DOWNLOADREAD)
		Local $nElapsed = TimerDiff($iSpeedTimer)
		If $nElapsed >= 700 Then
			$nSpeed = ($iNow - $iLastSize) / ($nElapsed / 1000)
			$iLastSize = $iNow
			$iSpeedTimer = TimerInit()
		EndIf
		If $sProgressCallback <> "" Then Call($sProgressCallback, $iNow, $nSpeed)
	WEnd

	Local $bOk = Not InetGetInfo($hDownload, $INET_DOWNLOADERROR)
	InetClose($hDownload)
	If Not $bOk Then Return SetError(3, 0, 0)

	Return TimerDiff($iTotalTimer) / 1000
EndFunc   ;==>_Net_DownloadInet
