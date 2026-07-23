namespace Deskestro.Windows.TestApp;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new FixtureForm());
    }
}

internal sealed class FixtureForm : Form
{
    private readonly TextBox input = new()
    {
        Name = "Input",
        AccessibleName = "Input",
        PlaceholderText = "Type a status",
        Location = new Point(24, 24),
        Width = 320
    };

    private readonly Label status = new()
    {
        Name = "Status",
        Text = "Waiting",
        AutoSize = true,
        Location = new Point(24, 230)
    };

    private readonly GesturePanel gestureTarget = new()
    {
        Name = "GestureTarget",
        AccessibleName = "Gesture target",
        BackColor = Color.SteelBlue,
        Location = new Point(24, 130),
        Size = new Size(320, 80)
    };

    private bool dragging;
    private Point dragStart;
    private DateTime lastLeftClick;
    private int leftClickCount;

    internal FixtureForm()
    {
        Text = "Deskestro Windows Test Fixture";
        Name = "FixtureWindow";
        AccessibleName = "Deskestro Windows Test Fixture";
        ClientSize = new Size(390, 270);
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true;

        var apply = new Button
        {
            Name = "Apply",
            AccessibleName = "Apply",
            Text = "Apply",
            Location = new Point(24, 65),
            Width = 100
        };
        apply.Click += (_, _) => status.Text = input.Text;
        KeyDown += (_, eventArgs) =>
        {
            if (!eventArgs.Control || eventArgs.KeyCode != Keys.K) return;
            status.Text = "Shortcut";
            eventArgs.SuppressKeyPress = true;
        };

        var context = new ContextMenuStrip();
        context.Items.Add("Fixture context item");
        context.Opening += (_, _) =>
        {
            status.Text = "Right click";
            BeginInvoke(() => context.Close());
        };
        gestureTarget.ContextMenuStrip = context;
        gestureTarget.DoubleClick += (_, _) => status.Text = "Double click";
        gestureTarget.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button != MouseButtons.Left) return;
            var now = DateTime.UtcNow;
            leftClickCount = now - lastLeftClick <= TimeSpan.FromMilliseconds(500) ? leftClickCount + 1 : 1;
            lastLeftClick = now;
            if (leftClickCount >= 2) status.Text = "Double click";
        };
        gestureTarget.MouseDown += (_, eventArgs) =>
        {
            if (eventArgs.Button != MouseButtons.Left) return;
            dragging = true;
            dragStart = eventArgs.Location;
        };
        gestureTarget.MouseUp += (_, eventArgs) =>
        {
            if (!dragging) return;
            dragging = false;
            if (Math.Abs(eventArgs.X - dragStart.X) + Math.Abs(eventArgs.Y - dragStart.Y) > 20)
                status.Text = "Dragged";
        };
        Controls.Add(input);
        Controls.Add(apply);
        Controls.Add(gestureTarget);
        Controls.Add(status);
    }
}
