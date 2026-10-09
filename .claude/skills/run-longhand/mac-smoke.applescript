-- The Mac shell's smoke test, driven through the accessibility tree.
-- Arguments: the seeded recording's title, and the path of the click tool
-- (SwiftUI ignores System Events' own `click`).
on run argv
    set jobTitle to item 1 of argv
    set clickTool to item 2 of argv
    set failures to {}

    tell application "System Events"
        if not (exists process "Longhand") then error "Longhand is not running"
        tell process "Longhand"
            set frontmost to true
            delay 1
            if (count of windows) is 0 then error "no library window after launch"

            -- The seeded recording is listed.
            set rowElement to my findElement(window 1, jobTitle)
            if rowElement is missing value then
                set end of failures to "sidebar row '" & jobTitle & "' not found"
            else
                -- Select it with a real click at its centre.
                set {px, py} to position of rowElement
                set {sw, sh} to size of rowElement
                do shell script quoted form of clickTool & " " & (px + sw / 2) & " " & (py + sh / 2)
                delay 2
                if my findElement(window 1, "Speaker 1") is missing value then
                    set end of failures to "transcript did not show a speaker chip after selecting the row"
                end if
            end if

            -- The verbs this batch and the ones before it put in the menus.
            set fileItems to name of menu items of menu 1 of menu bar item "File" of menu bar 1
            if fileItems does not contain "New Recording" then set end of failures to "File menu lacks New Recording"
            if fileItems does not contain "Import…" then set end of failures to "File menu lacks Import…"
            if fileItems does not contain "Open Recent" then set end of failures to "File menu lacks Open Recent"
            set recentItems to name of menu items of menu 1 of menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1
            if recentItems does not contain jobTitle then set end of failures to "Open Recent does not list the seeded recording"
            set editItems to name of menu items of menu 1 of menu bar item "Edit" of menu bar 1
            if editItems does not contain "Select Passages" then set end of failures to "Edit menu lacks Select Passages"
            if editItems does not contain "Delete Recording…" then set end of failures to "Edit menu lacks Delete Recording…"
            set windowItems to name of menu items of menu 1 of menu bar item "Window" of menu bar 1
            if windowItems does not contain "Longhand Library" then set end of failures to "Window menu lacks Longhand Library"

            -- A closed library window is not the end: the app runs on, the
            -- File menu still works, and the Window menu brings it back.
            keystroke "w" using command down
            delay 1.5
            if (count of windows) is not 0 then set end of failures to "Command-W did not close the library window"
            if not (enabled of menu item "New Recording" of menu 1 of menu bar item "File" of menu bar 1) then
                set end of failures to "New Recording is disabled with the window closed"
            end if
            if not (enabled of menu item "Import…" of menu 1 of menu bar item "File" of menu bar 1) then
                set end of failures to "Import… is disabled with the window closed"
            end if
            click menu item "Longhand Library" of menu 1 of menu bar item "Window" of menu bar 1
            delay 2
            if (count of windows) is 0 then set end of failures to "Window > Longhand Library did not reopen the window"
        end tell
    end tell

    if (count of failures) > 0 then
        set AppleScript's text item delimiters to linefeed
        error (failures as text)
    end if
    return "ok"
end run

-- The first element anywhere under `root` whose value, title or description
-- contains `needle`. SwiftUI's tree is deep and the paths move between
-- releases, so the search is by content, not by path.
on findElement(root, needle)
    tell application "System Events"
        repeat with e in (entire contents of root)
            try
                set v to value of e
                if v is not missing value and (v as text) contains needle then return contents of e
            end try
            try
                set t to title of e
                if t is not missing value and (t as text) contains needle then return contents of e
            end try
            try
                set d to description of e
                if d is not missing value and (d as text) contains needle then return contents of e
            end try
        end repeat
    end tell
    return missing value
end findElement
