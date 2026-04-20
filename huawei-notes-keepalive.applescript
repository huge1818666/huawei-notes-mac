use AppleScript version "2.4"
use scripting additions

property targetUrl : "https://cloud.huawei.com/"
property targetHost : "cloud.huawei.com"
property keepAliveEverySeconds : 240
property safeReloadAfterIdleSeconds : 75
property forceReloadEveryCycle : false

on run
	repeat
		try
			my ensureTargetTab()
			if my userIdleSeconds() is greater than or equal to safeReloadAfterIdleSeconds then
				my keepTargetSessionAlive()
			end if
		on error errMsg number errNum
			display notification errMsg with title "Huawei Notes Wrapper" subtitle ("AppleScript error " & errNum)
		end try
		delay keepAliveEverySeconds
	end repeat
end run

on ensureTargetTab()
	tell application "Safari"
		if not running then launch
		activate
		if (count of windows) = 0 then
			make new document with properties {URL:targetUrl}
			return
		end if
	end tell
	
	set tabInfo to my findTargetTab()
	if tabInfo is missing value then
		tell application "Safari"
			tell front window
				make new tab with properties {URL:targetUrl}
				set current tab to last tab
			end tell
		end tell
	end if
end ensureTargetTab

on keepTargetSessionAlive()
	set tabInfo to my findTargetTab()
	if tabInfo is missing value then return
	
	set windowIndex to windowIndex of tabInfo
	set tabIndex to tabIndex of tabInfo
	set pageState to my detectPageState(windowIndex, tabIndex)
	
	if pageState is "editing" then return
	
	if pageState is "login" then
		display notification "Session looks expired. Reopen the tab and sign in again if needed." with title "Huawei Notes Wrapper"
		return
	end if
	
	if forceReloadEveryCycle or pageState is "offline" then
		tell application "Safari"
			do JavaScript "window.location.reload();" in tab tabIndex of window windowIndex
		end tell
		return
	end if
	
	tell application "Safari"
		do JavaScript "void fetch(window.location.href, {credentials:'include', cache:'no-store'});" in tab tabIndex of window windowIndex
	end tell
end keepTargetSessionAlive

on detectPageState(windowIndex, tabIndex)
	set js to "(() => {" & ¬
		"const focused = document.activeElement;" & ¬
		"const editing = !!(focused && (focused.matches('input, textarea, [contenteditable=\"true\"]') || focused.closest('[contenteditable=\"true\"]')));" & ¬
		"if (editing) return 'editing';" & ¬
		"const title = (document.title || '').toLowerCase();" & ¬
		"const href = (location.href || '').toLowerCase();" & ¬
		"const text = ((document.body && document.body.innerText) || '').slice(0, 3000).toLowerCase();" & ¬
		"const loginLike = /(login|signin|passport|account|auth|登录)/i.test(title + ' ' + href + ' ' + text);" & ¬
		"if (loginLike) return 'login';" & ¬
		"const offlineLike = /(offline|network error|重新连接|连接已断开|网络异常|离线)/i.test(text);" & ¬
		"if (offlineLike) return 'offline';" & ¬
		"return 'ok';" & ¬
		"})();"
	
	tell application "Safari"
		return (do JavaScript js in tab tabIndex of window windowIndex) as text
	end tell
end detectPageState

on findTargetTab()
	tell application "Safari"
		repeat with w from 1 to (count of windows)
			set tabCount to (count of tabs of window w)
			repeat with t from 1 to tabCount
				try
					set currentUrl to URL of tab t of window w
					if currentUrl contains targetHost then return {windowIndex:w, tabIndex:t, url:currentUrl}
				end try
			end repeat
		end repeat
	end tell
	return missing value
end findTargetTab

on userIdleSeconds()
	try
		return (do shell script "ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'") as integer
	on error
		return safeReloadAfterIdleSeconds
	end try
end userIdleSeconds
