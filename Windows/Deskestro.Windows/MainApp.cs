using Deskestro.Windows.Automation;
using Deskestro.Windows.Protocol;
using Deskestro.Windows.Tools;

namespace Deskestro.Windows;

internal static class MainApp
{
    public static int Run()
    {
        Console.InputEncoding = System.Text.Encoding.UTF8;
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        NativeMethods.EnablePerMonitorDpiAwareness();

        try
        {
            new StdioMcpServer(new ToolRegistry()).Run();
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"deskestro-windows fatal: {ex}");
            return 1;
        }
    }
}
