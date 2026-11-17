// RemoteDeskSetup.exe — one file to download: a tiny starter with the whole program (a zip)
// glued to its end. One click: unpacks into %LOCALAPPDATA%\Programs\RemoteDesk, puts a shortcut
// on the desktop and starts the program. Clicked again later, it just opens the program.
// Built by make_setup.py (csc from .NET Framework 4, which every Windows 10/11 has).
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

/// <summary>The zip glued to the end of this exe, seen as a file of its own.</summary>
class Tail : Stream
{
    readonly Stream f; readonly long start, len; long pos;
    public Tail(Stream f, long start) { this.f = f; this.start = start; len = f.Length - start; }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return true; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { return len; } }
    public override long Position { get { return pos; } set { pos = value; } }
    public override void Flush() { }
    public override int Read(byte[] b, int o, int n)
    {
        if (pos >= len) return 0;
        f.Position = start + pos;
        int got = f.Read(b, o, (int)Math.Min(n, len - pos));
        pos += got;
        return got;
    }
    public override long Seek(long o, SeekOrigin from)
    {
        pos = from == SeekOrigin.Begin ? o : from == SeekOrigin.Current ? pos + o : len + o;
        return pos;
    }
    public override void SetLength(long v) { throw new NotSupportedException(); }
    public override void Write(byte[] b, int o, int n) { throw new NotSupportedException(); }
}

class Win : Form
{
    string status = "Подготовка…";
    double part;
    readonly float k;

    public Win()
    {
        using (Graphics g = CreateGraphics()) k = g.DpiX / 96f;
        Text = "RemoteDesk";
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.Black;
        DoubleBuffered = true;
        ClientSize = new Size(P(440), P(150));
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(wa.X + (wa.Width - Width) / 2, wa.Y + (wa.Height - Height) / 2);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        using (GraphicsPath p = Rounded(new Rectangle(0, 0, Width, Height), P(22))) Region = new Region(p);
        Shown += delegate { new Thread(Work) { IsBackground = true }.Start(); };
    }

    int P(int n) { return (int)Math.Round(n * k); }

    static GraphicsPath Rounded(Rectangle r, int rad)
    {
        int d = rad * 2;
        GraphicsPath p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int x = P(28);
        if (Icon != null)
        {
            using (Bitmap b = new Icon(Icon, 48, 48).ToBitmap())
                g.DrawImage(b, x, P(24), P(36), P(36));
            x += P(48);
        }
        float tw;
        using (Font f = new Font("Segoe UI", 15, FontStyle.Bold))
        {
            g.DrawString("RemoteDesk", f, Brushes.White, x, P(22));
            tw = g.MeasureString("RemoteDesk", f).Width;
        }
        using (Font f = new Font("Segoe UI", 8))
        using (Brush b = new SolidBrush(Color.FromArgb(0x6B, 0x6B, 0x73)))
            g.DrawString(Ver.V, f, b, x + tw, P(34));
        using (Font f = new Font("Segoe UI", 9.5f))
        using (Brush b = new SolidBrush(Color.FromArgb(0xC7, 0xC7, 0xCC)))
        {
            g.DrawString(status, f, b, P(26), P(82));
            string pct = (int)(part * 100) + "%";
            g.DrawString(pct, f, b, Width - P(28) - g.MeasureString(pct, f).Width, P(82));
        }
        Rectangle bar = new Rectangle(P(28), P(114), Width - P(56), P(6));
        using (Brush b = new SolidBrush(Color.FromArgb(0x23, 0x23, 0x27)))
        using (GraphicsPath p = Rounded(bar, bar.Height / 2)) g.FillPath(b, p);
        int w = (int)(bar.Width * part);
        if (w > bar.Height)
            using (GraphicsPath p = Rounded(new Rectangle(bar.X, bar.Y, w, bar.Height), bar.Height / 2))
                g.FillPath(Brushes.White, p);
    }

    void Say(string s, double p)
    {
        status = s; part = p;
        try { BeginInvoke((MethodInvoker)Invalidate); } catch { }
    }

    void Work()
    {
        try
        {
            Program.Unpack(Say);
            Say("Запускаю…", 1);
            Program.Shortcuts();
            Program.Start();
            Thread.Sleep(700);
        }
        catch (Exception e)
        {
            MessageBox.Show("Не удалось установить RemoteDesk:\n" + e.Message, "RemoteDesk",
                            MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        Environment.Exit(0);
    }
}

static class Program
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);

    // REMOTEDESK_SETUP_DIR: another folder and no shortcuts — for testing the installer
    static readonly string Test = Environment.GetEnvironmentVariable("REMOTEDESK_SETUP_DIR");
    static readonly string Dir = !string.IsNullOrEmpty(Test) ? Test : Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "RemoteDesk");
    static string Exe { get { return Path.Combine(Dir, "RemoteDesk.exe"); } }

    [STAThread]
    static void Main()
    {
        try { SetProcessDPIAware(); } catch { }
        try
        {
            if (File.Exists(Exe) && Installed() >= new Version(Ver.V))
            {
                // already here: just open it (or bring its window forward when it is running)
                bool shown = false;
                foreach (Process p in Running())
                {
                    if (p.MainWindowHandle != IntPtr.Zero)
                    {
                        ShowWindow(p.MainWindowHandle, 9);
                        SetForegroundWindow(p.MainWindowHandle);
                    }
                    shown = true;
                }
                if (!shown) Start();
                return;
            }
        }
        catch { }
        Application.EnableVisualStyles();
        Application.Run(new Win());
    }

    static Version Installed()
    {
        FileVersionInfo v = FileVersionInfo.GetVersionInfo(Exe);
        return new Version(v.FileMajorPart, v.FileMinorPart, v.FileBuildPart);
    }

    /// <summary>Copies of the installed program that are running now.</summary>
    static System.Collections.Generic.List<Process> Running()
    {
        var list = new System.Collections.Generic.List<Process>();
        string dir = Path.GetFullPath(Dir).TrimEnd('\\') + "\\";
        foreach (string name in new[] { "RemoteDesk", "RemoteDeskUnlock" })
            foreach (Process p in Process.GetProcessesByName(name))
            {
                try
                {
                    if (p.MainModule.FileName.StartsWith(dir, StringComparison.OrdinalIgnoreCase)) list.Add(p);
                }
                catch { }
            }
        return list;
    }

    public static void Start()
    {
        ProcessStartInfo si = new ProcessStartInfo(Exe);
        si.WorkingDirectory = Dir;
        si.UseShellExecute = false;
        Process.Start(si);
    }

    /// <summary>Where this exe ends and the glued zip begins (end of the last PE section).</summary>
    static long ZipStart(FileStream f)
    {
        BinaryReader r = new BinaryReader(f);
        f.Position = 0x3C;
        int pe = r.ReadInt32();
        f.Position = pe + 6;
        int sections = r.ReadUInt16();
        f.Position = pe + 20;
        int opt = r.ReadUInt16();
        long end = 0;
        for (int i = 0; i < sections; i++)
        {
            f.Position = pe + 24 + opt + i * 40 + 16;
            long size = r.ReadUInt32(), at = r.ReadUInt32();
            end = Math.Max(end, at + size);
        }
        if (end <= 0 || end >= f.Length) throw new Exception("в файле нет программы (скачался не полностью?)");
        return end;
    }

    static void Drop(string dir)
    {
        for (int i = 0; Directory.Exists(dir); i++)
        {
            try { Directory.Delete(dir, true); }
            catch { if (i >= 20) throw; Thread.Sleep(300); }
        }
    }

    public static void Unpack(Action<string, double> say)
    {
        say("Подготовка…", 0);
        foreach (Process p in Running())  // an older version is open: close it first
        {
            try { p.Kill(); p.WaitForExit(8000); } catch { }
        }
        Directory.CreateDirectory(Dir);
        Drop(Path.Combine(Dir, "_internal"));  // no files of an older version left behind
        string root = Path.GetFullPath(Dir).TrimEnd('\\') + "\\";
        using (FileStream f = new FileStream(Application.ExecutablePath, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (ZipArchive zip = new ZipArchive(new Tail(f, ZipStart(f)), ZipArchiveMode.Read))
        {
            long total = 1, done = 0;
            foreach (ZipArchiveEntry e in zip.Entries) total += e.Length;
            byte[] buf = new byte[1 << 16];
            int tick = 0;
            foreach (ZipArchiveEntry e in zip.Entries)
            {
                string name = e.FullName.Replace('\\', '/');
                int cut = name.IndexOf('/');           // «RemoteDesk/…» -> «…»
                if (cut < 0 || cut == name.Length - 1) continue;
                string to = Path.GetFullPath(Path.Combine(Dir, name.Substring(cut + 1).Replace('/', '\\')));
                if (!to.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                if (name.EndsWith("/")) { Directory.CreateDirectory(to); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                using (Stream src = e.Open())
                using (FileStream dst = new FileStream(to, FileMode.Create, FileAccess.Write))
                {
                    int n;
                    while ((n = src.Read(buf, 0, buf.Length)) > 0)
                    {
                        dst.Write(buf, 0, n);
                        done += n;
                        if (Environment.TickCount - tick > 40)
                        {
                            tick = Environment.TickCount;
                            say("Устанавливаю…", (double)done / total);
                        }
                    }
                }
            }
        }
    }

    public static void Shortcuts()
    {
        if (!string.IsNullOrEmpty(Test)) return;
        foreach (Environment.SpecialFolder where in new[] { Environment.SpecialFolder.DesktopDirectory,
                                                            Environment.SpecialFolder.Programs })
        {
            try
            {
                object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
                string lnk = Path.Combine(Environment.GetFolderPath(where), "RemoteDesk.lnk");
                object s = shell.GetType().InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod,
                                                        null, shell, new object[] { lnk });
                Type t = s.GetType();
                System.Reflection.BindingFlags set = System.Reflection.BindingFlags.SetProperty;
                t.InvokeMember("TargetPath", set, null, s, new object[] { Exe });
                t.InvokeMember("WorkingDirectory", set, null, s, new object[] { Dir });
                t.InvokeMember("Description", set, null, s, new object[] { "RemoteDesk — управление компьютером с телефона" });
                t.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, s, null);
            }
            catch { }
        }
    }
}
