namespace AgentController.Windows.TestApp;

internal sealed class GesturePanel : Panel
{
    internal GesturePanel()
    {
        SetStyle(ControlStyles.StandardClick | ControlStyles.StandardDoubleClick, true);
    }
}
