// Private fureclaude terminal transport. SSH carries framed input and resize
// messages; OpenConsole owns the VM console. No system-wide hooks or settings.
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class FureclaudeTerminal
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll")] static extern uint GetConsoleCP();
    [DllImport("kernel32.dll")] static extern uint GetConsoleOutputCP();
    [DllImport("kernel32.dll")] static extern bool SetConsoleCP(uint cp);
    [DllImport("kernel32.dll")] static extern bool SetConsoleOutputCP(uint cp);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] static extern bool CancelSynchronousIo(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes sa, uint size);
    [DllImport("kernel32.dll")] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    [DllImport("kernel32.dll", EntryPoint="ReadConsoleInputW")] static extern bool ReadConsoleInput(IntPtr h, [Out] InputRecord[] records, uint count, out uint read);
    [StructLayout(LayoutKind.Explicit, Size=20)] struct InputRecord {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(4)] public int Down;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort Key;
        [FieldOffset(12)] public ushort Scan;
        [FieldOffset(14)] public char Character;
    }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Size; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }

    sealed class Worker
    {
        public Thread Thread;
        IntPtr nativeThread;
        readonly ManualResetEvent ready = new ManualResetEvent(false);
        public Worker(ThreadStart work)
        {
            Thread = new Thread(delegate() {
                nativeThread = OpenThread(1, false, GetCurrentThreadId());
                ready.Set();
                try { work(); } catch (IOException) {} catch (ObjectDisposedException) {}
            });
            Thread.IsBackground = true;
            Thread.Start();
            ready.WaitOne();
        }
        public void Stop()
        {
            if (!Thread.Join(300) && nativeThread != IntPtr.Zero) {
                CancelSynchronousIo(nativeThread);
                Thread.Join(1500);
            }
            if (nativeThread != IntPtr.Zero) { CloseHandle(nativeThread); nativeThread = IntPtr.Zero; }
            ready.Close();
        }
    }

    public static string Quote(string s)
    {
        var b = new StringBuilder("\""); int slashes = 0;
        foreach (char c in s) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append(c); }
            else { b.Append('\\', slashes); b.Append(c); }
            slashes = 0;
        }
        b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
    }

    static Process Start(string exe, string arguments)
    {
        var p = new Process();
        p.StartInfo = new ProcessStartInfo(exe, arguments) {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        // .NET Framework derives stdin's StreamWriter encoding from Console.
        // Its default UTF-8 BOM would corrupt our binary frame header.
        Encoding previous = Console.InputEncoding;
        try { Console.InputEncoding = new UTF8Encoding(false); p.Start(); }
        finally { Console.InputEncoding = previous; }
        return p;
    }

    static byte[] Size(int cols, int rows)
    {
        if (cols < 1 || rows < 1 || cols > 32767 || rows > 32767) throw new IOException("Invalid terminal size.");
        return new byte[] {(byte)cols, (byte)(cols >> 8), (byte)rows, (byte)(rows >> 8)};
    }
    static void Send(Stream s, object gate, byte type, byte[] data, int count)
    {
        lock (gate) {
            s.WriteByte(type); byte[] length = BitConverter.GetBytes(count);
            s.Write(length, 0, 4); s.Write(data, 0, count); s.Flush();
        }
    }
    static byte[] ReadExact(Stream s, int count)
    {
        var b = new byte[count]; int n = 0;
        while (n < count) { int k = s.Read(b, n, count-n); if (k == 0) throw new EndOfStreamException(); n += k; }
        return b;
    }
    static byte[] Receive(Stream s, out byte type)
    {
        int t = s.ReadByte(); if (t < 0) throw new EndOfStreamException(); type = (byte)t;
        int n = BitConverter.ToInt32(ReadExact(s, 4), 0);
        if (n < 0 || n > 65536 || (type != 73 && type != 82) || (type == 82 && n != 4)) throw new IOException("Invalid terminal frame.");
        return ReadExact(s, n);
    }

    public static int Client(string ssh, string[] args)
    {
        IntPtr input = GetStdHandle(-10), output = GetStdHandle(-11);
        uint im, om;
        if (!GetConsoleMode(input, out im) || !GetConsoleMode(output, out om)) throw new IOException("An interactive terminal is required.");
        uint cp = GetConsoleCP(), ocp = GetConsoleOutputCP();
        var cmd = new StringBuilder(); foreach (string arg in args) { if (cmd.Length > 0) cmd.Append(' '); cmd.Append(Quote(arg)); }
        Process p = null; Worker reader = null, writer = null, errors = null;
        var gate = new object();
        try {
            if (!SetConsoleMode(input, (im & ~0x77u) | 0x208u) || !SetConsoleMode(output, om | 0xCu)) throw new IOException("Cannot enter terminal raw mode.");
            SetConsoleCP(65001); SetConsoleOutputCP(65001);
            p = Start(ssh, cmd.ToString());
            errors = new Worker(delegate() { p.StandardError.BaseStream.CopyTo(Console.OpenStandardError()); });
            Stream toVm = p.StandardInput.BaseStream;
            int cols = Console.WindowWidth, rows = Console.WindowHeight;
            Send(toVm, gate, 82, Size(cols, rows), 4);
            writer = new Worker(delegate() { p.StandardOutput.BaseStream.CopyTo(Console.OpenStandardOutput()); });
            reader = new Worker(delegate() {
                // ReadConsoleInput preserves VT characters. ReadFile can instead
                // return Windows' encoded key-event packets on recent ConPTY.
                var events = new InputRecord[128]; var encoder = Encoding.UTF8.GetEncoder();
                try {
                    uint count;
                    while (ReadConsoleInput(input, events, (uint)events.Length, out count)) {
                        var text = new StringBuilder();
                        for (int i = 0; i < count; i++) {
                            var e = events[i];
                            if (e.Type == 1 && (e.Down != 0 || e.Key == 18) && (e.Character != 0 || e.Scan == 0))
                                text.Append(e.Character, Math.Max(1, (int)e.Repeat));
                        }
                        if (text.Length == 0) continue;
                        char[] chars = text.ToString().ToCharArray();
                        byte[] bytes = new byte[Encoding.UTF8.GetMaxByteCount(chars.Length)];
                        int length = encoder.GetBytes(chars, 0, chars.Length, bytes, 0, false);
                        for (int at = 0; at < length; at += 32768) {
                            int n = Math.Min(32768, length-at); var part = new byte[n]; Array.Copy(bytes, at, part, 0, n);
                            Send(toVm, gate, 73, part, n);
                        }
                    }
                }
                finally { try { toVm.Close(); } catch (IOException) {} }
            });
            while (!p.WaitForExit(150)) {
                int c = Console.WindowWidth, r = Console.WindowHeight;
                if (c > 0 && r > 0 && (c != cols || r != rows)) {
                    Send(toVm, gate, 82, Size(c, r), 4); cols = c; rows = r;
                }
            }
            writer.Thread.Join(3000);
            return p.ExitCode;
        }
        finally {
            if (reader != null) reader.Stop();
            if (p != null) { try { if (!p.HasExited) p.Kill(); } catch (InvalidOperationException) {} }
            if (writer != null) writer.Stop();
            if (errors != null) errors.Stop();
            // Also repair the terminal after a disconnected SSH session.
            Console.Write("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?1004l\x1b[?2031l\x1b[?1049l\x1b[?25h\x1b[0m");
            SetConsoleMode(input, im); SetConsoleMode(output, om);
            SetConsoleCP(cp); SetConsoleOutputCP(ocp);
            if (p != null) p.Dispose();
        }
    }

    public static int Server(string openConsole, string encodedScript)
    {
        Stream fromHost = new FileStream(new SafeFileHandle(GetStdHandle(-10), false), FileAccess.Read, 4096); byte type;
        byte[] initial = Receive(fromHost, out type);
        if (type != 82) throw new IOException("Missing initial terminal size.");
        int cols = BitConverter.ToUInt16(initial, 0), rows = BitConverter.ToUInt16(initial, 2);
        Size(cols, rows);
        var sa = new SecurityAttributes { Size = Marshal.SizeOf(typeof(SecurityAttributes)), Inherit = true };
        IntPtr signalRead, signalWrite;
        if (!CreatePipe(out signalRead, out signalWrite, ref sa, 0)) throw new System.ComponentModel.Win32Exception();
        SetHandleInformation(signalWrite, 1, 0);
        var signal = new FileStream(new SafeFileHandle(signalWrite, true), FileAccess.Write);
        Process p = null; Worker reader = null, writer = null, errors = null;
        try {
            string args = "--headless --width " + cols + " --height " + rows + " --signal 0x" + signalRead.ToInt64().ToString("x") +
                " -- powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encodedScript;
            p = Start(openConsole, args);
            errors = new Worker(delegate() { p.StandardError.BaseStream.CopyTo(Console.OpenStandardError()); });
            CloseHandle(signalRead); signalRead = IntPtr.Zero;
            writer = new Worker(delegate() { p.StandardOutput.BaseStream.CopyTo(Console.OpenStandardOutput()); });
            reader = new Worker(delegate() {
                try {
                    while (true) {
                        byte t; byte[] data = Receive(fromHost, out t);
                        if (t == 73) { p.StandardInput.BaseStream.Write(data, 0, data.Length); p.StandardInput.BaseStream.Flush(); }
                        else {
                            Size(BitConverter.ToUInt16(data, 0), BitConverter.ToUInt16(data, 2));
                            // OpenConsole PTY_SIGNAL_RESIZE_WINDOW: three little-endian ushorts.
                            signal.Write(new byte[] {8, 0, data[0], data[1], data[2], data[3]}, 0, 6); signal.Flush();
                        }
                    }
                }
                finally { signal.Close(); try { p.StandardInput.Close(); } catch (IOException) {} }
            });
            p.WaitForExit(); writer.Thread.Join(3000);
            return p.ExitCode;
        }
        finally {
            if (reader != null) reader.Stop();
            signal.Close();
            if (signalRead != IntPtr.Zero) CloseHandle(signalRead);
            if (p != null) { try { if (!p.HasExited) p.Kill(); } catch (InvalidOperationException) {} }
            if (writer != null) writer.Stop();
            if (errors != null) errors.Stop();
            if (p != null) p.Dispose();
        }
    }
}
