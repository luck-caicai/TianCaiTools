using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ImagePaste;

internal record PasteRequest(nint Window, nint Focus, nint View, bool Desktop, uint ClipboardVersion);

internal static class PasteTarget
{
    internal static PasteRequest? Capture()
    {
        nint window = Native.GetForegroundWindow();
        string type = Native.ClassName(window);
        if (type == "TXMiniSkin") return CaptureTencentDesktop(window);
        bool desktop = type is "Progman" or "WorkerW";
        if (!desktop && type is not ("CabinetWClass" or "ExploreWClass")) return null;
        uint thread = Native.GetWindowThreadProcessId(window, out uint process);
        uint shellProcess = 0;
        if (desktop)
        {
            Native.GetWindowThreadProcessId(Native.GetShellWindow(), out shellProcess);
            if (shellProcess == 0 || process != shellProcess) return null;
        }
        var info = new Native.GuiThreadInfo { Size = (uint)Marshal.SizeOf<Native.GuiThreadInfo>() };
        if (!Native.GetGUIThreadInfo(thread, ref info) || !AllowsShortcut(info.Flags)) return null;
        // Showing the desktop can focus its host (or nothing), while Explorer keeps
        // the icon view under a separate WorkerW. Never use this fallback for edits.
        if (desktop)
        {
            nint view = FindDesktopView(window, shellProcess);
            if (view != 0 && AllowsDesktopFallback(info.Focus, window, Native.GetParent(view), Native.ClassName(info.Focus)))
                return new(window, info.Focus, view, true, Native.GetClipboardSequenceNumber());
        }
        // Only a shell file view may receive the shortcut. Edit controls include file rename.
        string focusClass = Native.ClassName(info.Focus);
        if (focusClass is not ("DirectUIHWND" or "SysListView32" or "SHELLDLL_DefView")) return null;
        nint ancestor = info.Focus;
        for (int i = 0; ancestor != 0 && i < 24; i++, ancestor = Native.GetParent(ancestor))
        {
            if (Native.ClassName(ancestor) == "SHELLDLL_DefView")
                return new(window, info.Focus, ancestor, desktop, Native.GetClipboardSequenceNumber());
        }
        return null;
    }

    internal static bool AllowsShortcut(uint flags) => (flags & 0x1e) == 0; // Moving/sizing and menus; blinking caret alone is harmless.

    private static PasteRequest? CaptureTencentDesktop(nint window)
    {
        uint thread = Native.GetWindowThreadProcessId(window, out uint processId);
        var info = new Native.GuiThreadInfo { Size = (uint)Marshal.SizeOf<Native.GuiThreadInfo>() };
        if (!Native.GetGUIThreadInfo(thread, ref info) || !Native.GetWindowRect(window, out var rect)) return null;
        var work = Screen.FromHandle(window).WorkingArea;
        bool coversDesktop = rect.Left <= work.Left && rect.Top <= work.Top && rect.Right >= work.Right && rect.Bottom >= work.Bottom;
        try
        {
            using var process = Process.GetProcessById((int)processId);
            if (!IsTencentDesktopTarget(process.ProcessName, info.Focus == window, info.Flags, coversDesktop)) return null;
            return new(window, info.Focus, window, true, Native.GetClipboardSequenceNumber());
        }
        catch (ArgumentException) { return null; }
        catch (Win32Exception) { return null; }
    }

    // DeskGo owns a separate full-desktop window. Its rename/search child controls
    // and smaller organizer panels must retain their own paste behavior.
    internal static bool IsTencentDesktopTarget(string processName, bool hostFocused, uint flags, bool coversDesktop) =>
        (processName.Equals("DesktopMgr64", StringComparison.OrdinalIgnoreCase)
            || processName.Equals("DesktopMgr", StringComparison.OrdinalIgnoreCase))
        && hostFocused && AllowsShortcut(flags) && coversDesktop;

    internal static bool AllowsDesktopFallback(nint focus, nint window, nint viewHost, string focusClass) =>
        focus == 0 || ((focus == window || focus == viewHost) && focusClass is "Progman" or "WorkerW");

    private static nint FindDesktopView(nint foreground, uint shellProcess)
    {
        nint view = Native.FindWindowEx(foreground, 0, "SHELLDLL_DefView", null);
        if (view != 0 && Native.IsWindowVisible(view)) return view;
        // Only Progman may delegate to another desktop host. An unrelated WorkerW
        // without an icon view must not be treated as the desktop.
        if (foreground != Native.GetShellWindow()) return 0;
        for (nint host = Native.FindWindowEx(0, 0, "WorkerW", null); host != 0;
            host = Native.FindWindowEx(0, host, "WorkerW", null))
        {
            Native.GetWindowThreadProcessId(host, out uint process);
            if (process != shellProcess) continue;
            view = Native.FindWindowEx(host, 0, "SHELLDLL_DefView", null);
            if (view != 0 && Native.IsWindowVisible(view)) return view;
        }
        return 0;
    }

    internal static bool StillCurrent(PasteRequest request)
    {
        var current = Capture();
        return current != null && current.Window == request.Window && current.Focus == request.Focus
            && current.View == request.View;
    }
}

internal sealed class PasteHook : IDisposable
{
    private readonly Native.HookProc callback;
    private readonly Thread thread;
    private readonly Action<PasteRequest> submit;
    private readonly ManualResetEventSlim ready = new(false);
    private nint hook;
    private uint threadId;
    private Exception? startupError;
    private bool vDown, suppressV;
    internal volatile bool Enabled = true;

    internal PasteHook(Action<PasteRequest> submit)
    {
        this.submit = submit;
        callback = OnKey;
        thread = new Thread(Run) { IsBackground = true, Name = "ImagePaste keyboard" };
        thread.Start();
        ready.Wait();
        if (startupError != null) throw startupError;
    }

    private void Run()
    {
        threadId = Native.GetCurrentThreadId();
        hook = Native.SetWindowsHookEx(13, callback, Native.GetModuleHandle(null), 0);
        if (hook == 0) startupError = new Win32Exception(Marshal.GetLastWin32Error());
        ready.Set();
        if (hook == 0) return;
        try { while (Native.GetMessage(out _, 0, 0, 0) > 0) { } }
        finally { Native.UnhookWindowsHookEx(hook); }
    }

    private nint OnKey(int code, nint message, nint data)
    {
        if (code < 0) return Native.CallNextHookEx(hook, code, message, data);
        var key = Marshal.PtrToStructure<Native.KeyboardData>(data);
        if (key.Key != 0x56)
            return Native.CallNextHookEx(hook, code, message, data);
        bool up = message == 0x101 || message == 0x105;
        if (up)
        {
            bool swallowed = suppressV;
            vDown = suppressV = false;
            return swallowed ? 1 : Native.CallNextHookEx(hook, code, message, data);
        }
        if (vDown) return suppressV ? 1 : Native.CallNextHookEx(hook, code, message, data);
        vDown = true;
        try
        {
            bool ctrl = Native.GetAsyncKeyState(0x11) < 0;
            bool modified = Native.GetAsyncKeyState(0x10) < 0 || Native.GetAsyncKeyState(0x12) < 0
                || Native.GetAsyncKeyState(0x5B) < 0 || Native.GetAsyncKeyState(0x5C) < 0;
            if (Enabled && ctrl && !modified && !Native.HasFiles() && Native.HasImage()
                && PasteTarget.Capture() is { } target)
            {
                submit(target);
                suppressV = true;
                return 1;
            }
        }
        catch (Exception ex) { ThreadPool.QueueUserWorkItem(_ => AppLog.Write(ex)); }
        return Native.CallNextHookEx(hook, code, message, data);
    }

    public void Dispose()
    {
        Native.PostThreadMessage(threadId, 0x12, 0, 0);
        thread.Join(2000);
        ready.Dispose();
    }
}
