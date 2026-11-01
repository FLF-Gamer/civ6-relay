using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Civ6Relay.Desktop
{
    public static class Dpi
    {
        [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] private static extern bool SetThreadDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        public static void Enable()
        {
            bool enabled = false;
            try { enabled = SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
            if (!enabled) { try { SetProcessDPIAware(); } catch (EntryPointNotFoundException) { } }
            try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { }
        }
    }
    public sealed class PeerRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private string player, virtualIP, channel, rtt, linkRTT, sampleTime, pathKind;
        public string Player { get { return player; } private set { Set(ref player, value, "Player"); } }
        public string VirtualIP { get { return virtualIP; } private set { Set(ref virtualIP, value, "VirtualIP"); } }
        public string Channel { get { return channel; } private set { Set(ref channel, value, "Channel"); } }
        public string RTT { get { return rtt; } private set { Set(ref rtt, value, "RTT"); } }
        public string LinkRTT { get { return linkRTT; } private set { Set(ref linkRTT, value, "LinkRTT"); } }
        public string SampleTime { get { return sampleTime; } private set { Set(ref sampleTime, value, "SampleTime"); } }
        public string PathKind { get { return pathKind; } private set { Set(ref pathKind, value, "PathKind"); } }
        private void Set(ref string field, string value, string property)
        {
            if (String.Equals(field, value, StringComparison.Ordinal)) return;
            field = value;
            var handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(property));
        }
        public void Update(string name, string ip, string path, string latency, string link, string time)
        {
            Player = name; VirtualIP = ip; Channel = path; RTT = latency; LinkRTT = link; SampleTime = time;
            PathKind = path == "P2P 直连" ? "Direct" : path == "服务器中继" ? "Relay" : "Other";
        }
    }
}
