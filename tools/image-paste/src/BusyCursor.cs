using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ImagePaste;

// Explorer owns the mouse cursor, so changing our hidden form's Cursor has no effect.
// A companion owns the temporary system cursor and restores it even if the tray app exits abruptly.
internal sealed class BusyCursor : IDisposable
{
    private readonly string token = "Local\\TianCai.ImagePaste.Cursor." + Guid.NewGuid().ToString("N");
    private readonly EventWaitHandle active, changed, acknowledged, ready, stop;
    private readonly Process guard;
    private bool disposed;
    internal int GuardId => guard.Id;
    internal long GuardStart => guard.StartTime.ToUniversalTime().Ticks;

    internal BusyCursor()
    {
        active = Create(".active", EventResetMode.ManualReset);
        changed = Create(".changed", EventResetMode.AutoReset);
        acknowledged = Create(".ack", EventResetMode.AutoReset);
        ready = Create(".ready", EventResetMode.ManualReset);
        stop = Create(".stop", EventResetMode.ManualReset);
        using var parent = Process.GetCurrentProcess();
        var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        info.ArgumentList.Add("--cursor-guard");
        info.ArgumentList.Add(parent.Id.ToString());
        info.ArgumentList.Add(parent.StartTime.ToUniversalTime().Ticks.ToString());
        info.ArgumentList.Add(token);
        guard = Process.Start(info) ?? throw new InvalidOperationException("无法启动鼠标光标恢复进程。");
        if (!ready.WaitOne(5000))
        {
            Dispose();
            throw new InvalidOperationException("鼠标光标恢复进程未就绪。");
        }
    }

    private EventWaitHandle Create(string suffix, EventResetMode mode) => new(false, mode, token + suffix);
    internal void Begin() => SetBusy(true);
    internal void End() => SetBusy(false);
    private void SetBusy(bool value)
    {
        if (disposed) return;
        acknowledged.Reset();
        if (value) active.Set(); else active.Reset();
        changed.Set();
        // Ensure even a fast paste gets the cursor applied before work starts.
        if (!acknowledged.WaitOne(1000)) AppLog.Write(new TimeoutException("鼠标状态切换未确认。"));
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        stop.Set();
        guard.WaitForExit(2000);
        guard.Dispose();
        active.Dispose(); changed.Dispose(); acknowledged.Dispose(); ready.Dispose(); stop.Dispose();
    }

    internal static int RunGuard(int parentId, long startTicks, string token)
    {
        try
        {
            using var parent = Process.GetProcessById(parentId);
            if (parent.StartTime.ToUniversalTime().Ticks != startTicks) return 1;
            using var parentExit = new ProcessExitHandle(parent);
            using var active = EventWaitHandle.OpenExisting(token + ".active");
            using var changed = EventWaitHandle.OpenExisting(token + ".changed");
            using var acknowledged = EventWaitHandle.OpenExisting(token + ".ack");
            using var ready = EventWaitHandle.OpenExisting(token + ".ready");
            using var stop = EventWaitHandle.OpenExisting(token + ".stop");
            using var replacement = new CursorReplacement();
            ready.Set();
            while (WaitHandle.WaitAny(new WaitHandle[] { stop, parentExit, changed }) == 2)
            {
                if (active.WaitOne(0)) replacement.Apply(); else replacement.Restore();
                acknowledged.Set();
            }
            return 0;
        }
        catch (Exception ex) { AppLog.Write(ex); return 1; }
    }

    private sealed class ProcessExitHandle : WaitHandle
    {
        internal ProcessExitHandle(Process process) => SafeWaitHandle = new SafeWaitHandle(process.Handle, false);
    }
}

internal sealed class CursorReplacement : IDisposable
{
    private nint original;
    internal void Apply()
    {
        if (original != 0) return;
        original = CopySystemCursor(32512); // OCR_NORMAL, snapshot current user theme.
        nint wait = CopySystemCursor(32514); // OCR_WAIT, preserves native animation.
        if (!SetSystemCursor(wait, 32512)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    internal void Restore()
    {
        if (original == 0) return;
        nint saved = original;
        original = 0;
        if (!SetSystemCursor(saved, 32512))
        {
            // Reload the user's configured scheme only if restoring the snapshot failed.
            if (!SystemParametersInfo(0x57, 0, 0, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
    public void Dispose() => Restore();
    private static nint CopySystemCursor(int id)
    {
        nint source = LoadCursor(0, (nint)id);
        nint copy = CopyImage(source, 2, 0, 0, 0); // IMAGE_CURSOR; CopyIcon loses animated cursors.
        if (copy == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        return copy;
    }
    [DllImport("user32.dll", SetLastError = true)] internal static extern nint LoadCursor(nint instance, nint name);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint CopyImage(nint image, uint type, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SetSystemCursor(nint cursor, uint id);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SystemParametersInfo(uint action, uint param, nint data, uint flags);
}
