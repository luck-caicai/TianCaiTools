using System.Runtime.InteropServices;
using System.Text;

namespace ImagePaste;

internal static class ShellFolder
{
    internal record ViewInfo(long Window, long View, string? Path);

    // Read-only diagnostic also exercises the COM interface layouts against real Explorer views.
    internal static List<ViewInfo> InspectViews()
    {
        var result = new List<ViewInfo>();
        object? windows = null;
        try
        {
            windows = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39"), true)!);
            dynamic collection = windows!;
            int count = collection.Count;
            for (int i = 0; i < count; i++)
            {
                object? entry = null, browser = null, view = null, folder = null;
                nint pidl = 0;
                try
                {
                    entry = collection.Item(i);
                    if (entry == null) continue;
                    var serviceId = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
                    var browserId = typeof(IShellBrowser).GUID;
                    ((IComServiceProvider)entry).QueryService(ref serviceId, ref browserId, out browser);
                    ((IShellBrowser)browser).QueryActiveShellView(out view);
                    ((IShellView)view).GetWindow(out nint viewWindow);
                    var folderId = typeof(IPersistFolder2).GUID;
                    ((IFolderView)view).GetFolder(ref folderId, out folder);
                    ((IPersistFolder2)folder).GetCurFolder(out pidl);
                    var path = new StringBuilder(32768);
                    bool hasPath = pidl != 0 && Native.SHGetPathFromIDListEx(pidl, path, (uint)path.Capacity, 0);
                    result.Add(new((long)((dynamic)entry).HWND, viewWindow.ToInt64(), hasPath ? path.ToString() : null));
                }
                finally
                {
                    if (pidl != 0) Marshal.FreeCoTaskMem(pidl);
                    Release(folder); Release(view); Release(browser); Release(entry);
                }
            }
        }
        finally { Release(windows); }
        return result;
    }

    internal static string Resolve(PasteRequest request)
    {
        if (!PasteTarget.StillCurrent(request)) throw new InvalidOperationException("粘贴位置已切换，请在目标文件夹重新按 Ctrl + V。");
        if (request.Desktop)
            return Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

        object? windows = null;
        try
        {
            windows = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39"), true)!);
            dynamic collection = windows!;
            int count = collection.Count;
            for (int i = 0; i < count; i++)
            {
                object? entry = null, browserObject = null, viewObject = null, folderObject = null;
                nint pidl = 0;
                try
                {
                    entry = collection.Item(i);
                    if (entry == null || (long)((dynamic)entry).HWND != request.Window.ToInt64()) continue;
                    var service = (IComServiceProvider)entry;
                    var serviceId = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
                    var browserId = typeof(IShellBrowser).GUID;
                    service.QueryService(ref serviceId, ref browserId, out browserObject);
                    ((IShellBrowser)browserObject).QueryActiveShellView(out viewObject);
                    ((IShellView)viewObject).GetWindow(out nint viewWindow);
                    // HWND alone is insufficient for Windows 11 tabs: match the focused view too.
                    if (!Native.IsWindowVisible(viewWindow) || (viewWindow != request.View
                        && !Native.IsChild(viewWindow, request.Focus))) continue;
                    var folderId = typeof(IPersistFolder2).GUID;
                    ((IFolderView)viewObject).GetFolder(ref folderId, out folderObject);
                    ((IPersistFolder2)folderObject).GetCurFolder(out pidl);
                    if (pidl == 0) continue;
                    var path = new StringBuilder(32768);
                    if (!Native.SHGetPathFromIDListEx(pidl, path, (uint)path.Capacity, 0)) continue;
                    if (!PasteTarget.StillCurrent(request)) throw new InvalidOperationException("粘贴位置已切换，请重试。");
                    return path.ToString();
                }
                catch (COMException) { /* A tab may have closed during enumeration. */ }
                finally
                {
                    if (pidl != 0) Marshal.FreeCoTaskMem(pidl);
                    Release(folderObject); Release(viewObject); Release(browserObject); Release(entry);
                }
            }
        }
        finally { Release(windows); }
        throw new InvalidOperationException("无法确定当前文件夹。请在普通文件夹的文件列表中粘贴；搜索结果、回收站等位置暂不支持。");
    }

    private static void Release(object? value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IComServiceProvider { void QueryService(ref Guid service, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object result); }
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellBrowser
    {
        void GetWindow(out nint window); void ContextSensitiveHelp(); void InsertMenusSB(); void SetMenuSB();
        void RemoveMenusSB(); void SetStatusTextSB(); void EnableModelessSB(); void TranslateAcceleratorSB();
        void BrowseObject(); void GetViewStateStream(); void GetControlWindow(); void SendControlMsg();
        void QueryActiveShellView([MarshalAs(UnmanagedType.Interface)] out object view);
    }
    [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellView { void GetWindow(out nint window); }
    [ComImport, Guid("CDE725B0-CCC9-4519-917E-325D72FAB4CE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFolderView
    {
        void GetCurrentViewMode(out uint mode); void SetCurrentViewMode(uint mode);
        void GetFolder(ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object folder);
    }
    [ComImport, Guid("1AC3D9F0-175C-11D1-95BE-00609797EA4F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFolder2
    {
        void GetClassID(out Guid id); void Initialize(nint pidl); void GetCurFolder(out nint pidl);
    }
}
