using AgentController.Windows.Automation;
using AgentController.Windows.Protocol;
using AgentController.Windows.Tools;

namespace AgentController.Windows;

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
            Console.Error.WriteLine($"agentcontroller-windows fatal: {ex}");
            return 1;
        }
    }
}
