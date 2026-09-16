using System.Runtime.InteropServices;
using System.Text;

namespace ImagePaste;

internal static class Native
{
    internal const uint CF_BITMAP = 2, CF_DIB = 8, CF_HDROP = 15, CF_DIBV5 = 17;
    internal static readonly uint Png = RegisterClipboardFormat("PNG");
    internal static readonly uint FileDescriptor = RegisterClipboardFormat("FileGroupDescriptorW");
    internal static readonly uint FileDescriptorAnsi = RegisterClipboardFormat("FileGroupDescriptor");
    internal static readonly uint ShellIdList = RegisterClipboardFormat("Shell IDList Array");
    internal delegate nint HookProc(int code, nint message, nint data);
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardData
    { public uint Key, ScanCode, Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct GuiThreadInfo
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretRect;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Message
    { public nint Window; public uint Id; public nuint WParam; public nint LParam; public uint Time; public int X, Y; public uint Private; }
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] internal static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] internal static extern nint GetParent(nint window);
    [DllImport("user32.dll")] internal static extern bool IsChild(nint parent, nint child);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder name, int count);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError = true)] internal static extern nint SetWindowsHookEx(int id, HookProc proc, nint module, uint thread);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? name);
    [DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] internal static extern int GetMessage(out Message message, nint window, uint min, uint max);
    [DllImport("user32.dll")] internal static extern bool PostThreadMessage(uint thread, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] internal static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] internal static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")] internal static extern bool CloseClipboard();
    [DllImport("user32.dll")] internal static extern nint GetClipboardData(uint format);
    [DllImport("kernel32.dll")] internal static extern nint GlobalLock(nint handle);
    [DllImport("kernel32.dll")] internal static extern bool GlobalUnlock(nint handle);
    [DllImport("kernel32.dll")] internal static extern nuint GlobalSize(nint handle);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] internal static extern bool SHGetPathFromIDListEx(nint pidl, StringBuilder path, uint length, uint flags);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] internal static extern void SHChangeNotify(uint id, uint flags, string path, nint other);

    internal static string ClassName(nint window)
    {
        var name = new StringBuilder(256);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }

    internal static bool HasImage() => IsClipboardFormatAvailable(Png) || IsClipboardFormatAvailable(CF_DIBV5)
        || IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP);
    internal static bool HasFiles() => IsClipboardFormatAvailable(CF_HDROP) || IsClipboardFormatAvailable(FileDescriptor)
        || IsClipboardFormatAvailable(FileDescriptorAnsi) || IsClipboardFormatAvailable(ShellIdList);
}
