using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Automation;

namespace Deskestro.Windows.Automation;

internal static class CaptureService
{
    internal static byte[] CaptureScreen()
    {
        var bounds = System.Windows.Forms.SystemInformation.VirtualScreen;
        using var bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
            graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
        return Encode(bitmap);
    }

    internal static byte[] CaptureWindow(nint hwnd)
    {
        if (!NativeMethods.GetWindowRect(hwnd, out var rect) || rect.Width <= 0 || rect.Height <= 0)
            throw new InvalidOperationException("Window has invalid bounds.");
        if (NativeMethods.IsIconic(hwnd))
            throw new InvalidOperationException("Minimized windows cannot be captured; restore_window first.");

        using var bitmap = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        var hdc = graphics.GetHdc();
        bool printed;
        try { printed = NativeMethods.PrintWindow(hwnd, hdc, 2); }
        finally { graphics.ReleaseHdc(hdc); }

        if (!printed)
            graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(rect.Width, rect.Height), CopyPixelOperation.SourceCopy);
        return Encode(bitmap);
    }

    internal static byte[] CaptureElement(AutomationElement element)
    {
        var rect = element.Current.BoundingRectangle;
        if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0)
            throw new InvalidOperationException("Element has invalid bounds.");
        if (element.Current.IsOffscreen)
            throw new InvalidOperationException("Element is offscreen and cannot be captured.");
        using var bitmap = new Bitmap((int)Math.Ceiling(rect.Width), (int)Math.Ceiling(rect.Height), PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
            graphics.CopyFromScreen((int)rect.X, (int)rect.Y, 0, 0, bitmap.Size, CopyPixelOperation.SourceCopy);
        return Encode(bitmap);
    }

    private static byte[] Encode(Bitmap bitmap)
    {
        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }
}
