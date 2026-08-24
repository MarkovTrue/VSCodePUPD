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
; Загрузка из интернета: опрос update API и скачивание архива.
; Модуль ничего не знает про GUI - о ходе работы сообщает колбэками,
; имена которых передаёт вызывающая сторона.
; ============================================================

Global Const $gc_iNetRetryCount = 5      ; столько раз curl сам переживает обрыв
Global Const $gc_iNetConnectTimeout = 15 ; с, ожидание установки соединения

; Откуда можно качать. Хеш приходит из того же ответа, что и ссылка, поэтому
; SHA-256 подтверждает целостность, но не источник - хост проверяем отдельно.
Global Const $gc_sTrustedHosts = "|microsoft.com|vo.msecnd.net|visualstudio.com|azureedge.net|windows.net|"


; Спрашивает update API и возвращает [версия, ссылка на архив, sha256, дата выпуска].
; Дата - unix-время в миллисекундах, как её отдаёт сервер.
; $iTimeout - мс, дольше ждать нельзя: лаунчер стоит перед запуском редактора.
; $sTickCallback вызывается в паузах ожидания (можно крутить анимацию).
; @error: 1 - ответа нет, 2 - ответ не разобран, 4 - ссылка ведёт на чужой хост.
Func _Net_CheckUpdate($sApiUrl, $iTimeout, $sTickCallback = "")
	; имя с PID: два запущенных экземпляра не должны читать чужой ответ
	Local $sTmp = @TempDir & "\vscodepupd_update_" & @AutoItPID & ".json"
	FileDelete($sTmp)

	Local $hDownload = InetGet($sApiUrl, $sTmp, $INET_FORCERELOAD, $INET_DOWNLOADBACKGROUND)
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


; Только HTTPS и только известные хосты Microsoft. Ссылку отдаёт сервер обновлений,
; а качаем мы по ней исполняемый код - принимать любой адрес нельзя.
Func _Net_IsTrustedUrl($sUrl)
	Local $aHost = StringRegExp($sUrl, '^https://([^/:]+)', 1)
	If @error Then Return False

	Local $sHost = StringLower($aHost[0])
	For $sDomain In StringSplit(StringTrimLeft(StringTrimRight($gc_sTrustedHosts, 1), 1), "|", 2)
		If $sHost = $sDomain Or StringRight($sHost, StringLen($sDomain) + 1) = "." & $sDomain Then Return True
	Next

	Return False
EndFunc   ;==>_Net_IsTrustedUrl


; Размер файла на сервере до начала загрузки. 0 - узнать не удалось.
; Спрашиваем у curl с жёстким таймаутом: InetGetSize блокирует поток без предела,
; а лаунчер в это время держит на экране окно проверки.
; $sTickCallback вызывается в паузах ожидания.
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

	; при -L заголовков несколько: нужен Content-Length последнего ответа
	Local $aLen = StringRegExp($sOut, '(?im)^Content-Length:\s*(\d+)', 3)
	If @error Then Return 0
	Return Int($aLen[UBound($aLen) - 1])
EndFunc   ;==>_Net_GetRemoteSize


; Качает $sUrl в $sFile. Основной путь - curl.exe из System32: он умеет докачку
; (-C -) и сам переживает обрывы. Прогресс снимаем размером файла на диске,
; поэтому stdout читать не нужно и вызывающий GUI не блокируется.
;
; $sProgressCallback($iDone, $nSpeed) - вызывается примерно раз в 120 мс.
; $sAbortCallback() - вернуть True, чтобы прервать загрузку.
; @error: 1 - процесс не запустился, 2 - прервано вызывающей стороной,
;         3 - curl вернул ошибку (@extended - его код возврата).
; Возвращает секунды, потраченные на загрузку.
Func _Net_Download($sUrl, $sFile, $iTotalSize, $sProgressCallback = "", $sAbortCallback = "")
	Local $sCurl = @SystemDir & "\curl.exe"
	If Not FileExists($sCurl) Then Return _Net_DownloadInet($sUrl, $sFile, $iTotalSize, $sProgressCallback, $sAbortCallback)

	Local $iAlready = _Util_FileSizeLive($sFile)
	If $iAlready > 0 And $iTotalSize > 0 And $iAlready >= $iTotalSize Then Return 0 ; архив уже лежит целиком

	Local $sCmd = '"' & $sCurl & '" -L -C - --retry ' & $gc_iNetRetryCount & ' --retry-delay 2 --retry-all-errors' & _
			' --connect-timeout ' & $gc_iNetConnectTimeout & ' --no-progress-meter -o "' & $sFile & '" "' & $sUrl & '"'

	Local $iPid = Run($sCmd, _Util_ParentDir($sFile), @SW_HIDE)
	If @error Then Return SetError(1, 0, 0)

	Local $iSpeedTimer = TimerInit(), $iTotalTimer = TimerInit()
	Local $iLastSize = $iAlready, $nSpeed = 0

	; Держим handle процесса: он не даёт системе выбросить запись о завершившемся
	; процессе, поэтому код возврата остаётся читаемым после выхода из цикла.
	; ProcessWaitClose с таймаутом 0 здесь не годится - это ожидание без предела.
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
	If $iExit <> 0 Then Return SetError(3, $iExit, 0)

	Return TimerDiff($iTotalTimer) / 1000
EndFunc   ;==>_Net_Download


; Запасной путь для систем без curl.exe: InetGet умеет фоновую загрузку,
; но докачки не поддерживает - при обрыве файл качается заново.
Func _Net_DownloadInet($sUrl, $sFile, $iTotalSize, $sProgressCallback = "", $sAbortCallback = "")
	#forceref $iTotalSize
	FileDelete($sFile)

	Local $hDownload = InetGet($sUrl, $sFile, $INET_FORCERELOAD, $INET_DOWNLOADBACKGROUND)
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


; Размер растущего файла, код возврата процесса и разбор пути живут в Util.au3:
; ими пользуются и модуль архива, и сам лаунчер.
