import CoreGraphics

/// The AppleScript Summon sends a browser so a web search opens in the Workspace you're in:
/// as a new tab in the browser's window here, or in a new window when it has none here (that
/// window then tiles here). Browsers.swift runs it.
public enum BrowserScript {
    public enum Dialect: Sendable { case chromium, safari }

    /// A new tab in the browser's window at `origin` (its top-left corner on screen, as
    /// Accessibility gives it), which LunchboxWM has just focused. Browsers that report window
    /// bounds (Chrome, Safari) find that exact window by its corner, so the tab can't land in a
    /// window parked in another Workspace. Others (Arc) use their front window: the one just
    /// focused.
    public static func newTab(_ dialect: Dialect, bundleID: String, url: String, windowAt origin: CGPoint?) -> String {
        let link = quoted(url)
        let find: String
        if let origin {
            let x = Int(origin.x.rounded()), y = Int(origin.y.rounded())
            find = """
              try
                repeat with w in windows
                  set b to bounds of w
                  if (item 1 of b) > \(x - 8) and (item 1 of b) < \(x + 8) and (item 2 of b) > \(y - 8) and (item 2 of b) < \(y + 8) then
                    set target to contents of w
                    exit repeat
                  end if
                end repeat
              end try

            """
        } else {
            find = ""
        }
        let open = switch dialect {
        case .chromium: "tell target to make new tab with properties {URL:\(link)}"
        case .safari: "tell target to set current tab to (make new tab with properties {URL:\(link)})"
        }
        return """
        tell application id \(quoted(bundleID))
          set target to front window
        \(find)  \(open)
          try
            set index of target to 1
          end try
          activate
        end tell
        """
    }

    /// A new window with the page in it.
    public static func newWindow(_ dialect: Dialect, bundleID: String, url: String) -> String {
        let link = quoted(url)
        let open = switch dialect {
        case .chromium:
            // Chrome's new window has a blank tab to fill; Arc's has none yet, so add one.
            """
              make new window
              try
                set URL of active tab of front window to \(link)
              on error
                tell front window to make new tab with properties {URL:\(link)}
              end try
            """
        case .safari:
            "  make new document with properties {URL:\(link)}"
        }
        return """
        tell application id \(quoted(bundleID))
        \(open)
          activate
        end tell
        """
    }

    /// `text` as an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
