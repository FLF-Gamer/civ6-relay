using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Civ6Relay.Live
{
    public sealed class RouteSample
    {
        public long Generation { get; private set; }
        public string Stdout { get; private set; }
        public string Error { get; private set; }
        public int ExitCode { get; private set; }
        public DateTimeOffset SampleTime { get; private set; }
        public bool Running { get; private set; }

        internal RouteSample(long generation, string stdout, string error, int exitCode,
            DateTimeOffset sampleTime, bool running)
        {
            Generation = generation;
            Stdout = stdout ?? String.Empty;
            Error = error ?? String.Empty;
            ExitCode = exitCode;
            SampleTime = sampleTime;
            Running = running;
        }
    }

    // All process creation, pipe reads, waits and termination run on background tasks.
    public sealed class RoutePoller : IDisposable
    {
        private readonly object gate = new object();
        private CancellationTokenSource cancellation;
        private Task worker;
        // Accessed only by the sequential worker chain, including across restarts.
        private Process ownedProcess;
        private bool disposed;
        private bool running;
        private long epoch;
        private long generation;
        private RouteSample latest = new RouteSample(0, String.Empty, String.Empty, 0,
            DateTimeOffset.MinValue, false);

        private sealed class Output
        {
            internal string Text;
            internal bool Truncated;
            internal bool Failed;
        }

        public void Start(string cliPath, string instanceId, int rpcPort)
        {
            if (String.IsNullOrWhiteSpace(cliPath)) throw new ArgumentException("cliPath");
            if (String.IsNullOrWhiteSpace(instanceId) || instanceId.Length > 128)
                throw new ArgumentException("instanceId");
            foreach (char c in instanceId)
                if (Char.IsControl(c)) throw new ArgumentException("instanceId");
            if (rpcPort < 1 || rpcPort > 65535) throw new ArgumentOutOfRangeException("rpcPort");

            CancellationTokenSource old;
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("RoutePoller");
                old = cancellation;
                var source = new CancellationTokenSource();
                cancellation = source;
                long version = ++epoch;
                running = true;
                latest = new RouteSample(++generation, String.Empty, String.Empty, 0,
                    DateTimeOffset.MinValue, true);
                Task previous = worker;
                worker = Task.Run(async delegate
                {
                    // A restart cannot overlap the CLI process owned by the previous run.
                    if (previous != null)
                    {
                        try { await previous.ConfigureAwait(false); }
                        catch { }
                    }
                    try { await RunAsync(cliPath, instanceId, rpcPort, version, source.Token).ConfigureAwait(false); }
                    finally { source.Dispose(); }
                });
            }
            Cancel(old);
        }

        public RouteSample ReadLatest()
        {
            lock (gate) { return latest; }
        }

        public void Stop()
        {
            CancellationTokenSource old;
            lock (gate)
            {
                old = cancellation;
                cancellation = null;
                ++epoch;
                running = false;
                latest = new RouteSample(++generation, latest.Stdout, latest.Error,
                    latest.ExitCode, latest.SampleTime, false);
            }
            Cancel(old);
        }

        public void Dispose()
        {
            lock (gate) { disposed = true; }
            Stop();
        }

        private static void Cancel(CancellationTokenSource source)
        {
            if (source == null) return;
            // Framework cancellation can inline await continuations, including process cleanup.
            ThreadPool.QueueUserWorkItem(delegate(object state)
            {
                try { ((CancellationTokenSource)state).Cancel(); }
                catch (ObjectDisposedException) { }
            }, source);
        }

        private async Task RunAsync(string path, string instance, int port, long version,
            CancellationToken token)
        {
            while (!token.IsCancellationRequested)
            {
                var elapsed = Stopwatch.StartNew();
                RouteSample sample;
                try { sample = await QueryAsync(path, instance, port, token).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
                catch { sample = new RouteSample(0, String.Empty, "query_failed", -1, DateTimeOffset.UtcNow, true); }
                lock (gate)
                {
                    if (version != epoch || !running || token.IsCancellationRequested) break;
                    latest = new RouteSample(++generation, sample.Stdout, sample.Error,
                        sample.ExitCode, sample.SampleTime, true);
                }
                int delay = Math.Max(0, 1000 - (int)Math.Min(elapsed.ElapsedMilliseconds, 1000));
                try { await Task.Delay(delay, token).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }

        private static async Task<Output> ReadOutputAsync(StreamReader reader, int limit)
        {
            var text = new StringBuilder();
            bool truncated = false;
            var buffer = new char[4096];
            try
            {
                int count;
                while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0)
                {
                    int keep = Math.Min(count, Math.Max(0, limit - text.Length));
                    if (keep > 0) text.Append(buffer, 0, keep);
                    if (keep != count) truncated = true;
                }
                return new Output { Text = text.ToString(), Truncated = truncated };
            }
            catch { return new Output { Text = String.Empty, Failed = true }; }
        }

        private async Task<RouteSample> QueryAsync(string path, string instance,
            int port, CancellationToken token)
        {
            if (ownedProcess != null)
            {
                if (!KillOwned(ownedProcess)) return Failure("previous_query_still_running", -1);
                ownedProcess.Dispose();
                ownedProcess = null;
            }
            var info = new ProcessStartInfo();
            info.FileName = path;
            info.Arguments = "-p 127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) +
                " -i " + QuoteArgument(instance) + " -o json route";
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = new UTF8Encoding(false);
            info.StandardErrorEncoding = new UTF8Encoding(false);
            Process process = null;
            try
            {
                token.ThrowIfCancellationRequested();
                try { process = Process.Start(info); }
                catch (System.ComponentModel.Win32Exception ex)
                {
                    return Failure("start_failed_" + ex.NativeErrorCode.ToString(CultureInfo.InvariantCulture), -1);
                }
                catch { return Failure("start_failed", -1); }
                if (process == null) return Failure("start_failed", -1);
                ownedProcess = process;
                Task<Output> stdout = ReadOutputAsync(process.StandardOutput, 524288);
                Task<Output> stderr = ReadOutputAsync(process.StandardError, 16384);
                var clock = Stopwatch.StartNew();
                while (!process.WaitForExit(0))
                {
                    token.ThrowIfCancellationRequested();
                    if (clock.ElapsedMilliseconds >= 3000)
                    {
                        KillOwned(process);
                        return Failure("timeout", -1);
                    }
                    await Task.Delay(50, token).ConfigureAwait(false);
                }
                token.ThrowIfCancellationRequested();
                int code = process.ExitCode;
                Task<Output[]> output = Task.WhenAll(stdout, stderr);
                if (await Task.WhenAny(output, Task.Delay(500)).ConfigureAwait(false) != output)
                    return Failure("output_read_failed", code);
                Output[] streams = await output.ConfigureAwait(false);
                if (streams[0].Failed || streams[1].Failed) return Failure("output_read_failed", code);
                if (code != 0) return Failure(ClassifyExit(code, streams[1].Text), code);
                if (streams[0].Truncated) return Failure("output_too_large", code);
                return new RouteSample(0, streams[0].Text, String.Empty, code, DateTimeOffset.UtcNow, true);
            }
            finally
            {
                if (process != null)
                {
                    bool exited = KillOwned(process);
                    // Closing our redirected handles also bounds reads if a descendant inherited a pipe.
                    try { process.StandardOutput.BaseStream.Close(); } catch { }
                    try { process.StandardError.BaseStream.Close(); } catch { }
                    try { process.StandardOutput.Close(); } catch { }
                    try { process.StandardError.Close(); } catch { }
                    if (exited)
                    {
                        process.Dispose();
                        ownedProcess = null;
                    }
                }
            }
        }

        private static RouteSample Failure(string error, int code)
        {
            return new RouteSample(0, String.Empty, error, code, DateTimeOffset.UtcNow, true);
        }

        private static bool KillOwned(Process process)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(500);
                }
                return process.HasExited;
            }
            catch { }
            return false;
        }

        private static string ClassifyExit(int code, string stderr)
        {
            string value = (stderr ?? String.Empty).ToLowerInvariant();
            if (value.Contains("instance not found") || value.Contains("no instance matches")) return "instance_not_found";
            if (value.Contains("refused") || value.Contains("timed out") || value.Contains("failed to connect") ||
                value.Contains("os error 10061") || value.Contains("os error 10060")) return "rpc_unavailable";
            if (value.Contains("unexpected argument") || value.Contains("unrecognized") || value.Contains("invalid value"))
                return "cli_version_mismatch";
            if (code == -1073741515 || code == -1073741701 || code == -1073741502) return "dll_load_failed";
            return "cli_exit_" + code.ToString(CultureInfo.InvariantCulture);
        }

        private static string QuoteArgument(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { ++slashes; continue; }
                if (c == '"') result.Append('\\', slashes * 2 + 1);
                else result.Append('\\', slashes);
                result.Append(c);
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }
    }

    public sealed class LatencySample
    {
        public string IP { get; private set; }
        public string Status { get; private set; }
        public long? RttMs { get; private set; }
        public DateTimeOffset Time { get; private set; }
        public DateTimeOffset SampleTime { get { return Time; } }
        public long Sequence { get; private set; }
        public string Error { get; private set; }

        internal LatencySample(string ip, string status, long? rtt, DateTimeOffset time,
            long sequence, string error)
        {
            IP = ip;
            Status = status;
            RttMs = rtt;
            Time = time;
            Sequence = sequence;
            Error = error ?? String.Empty;
        }
    }

    public sealed class LatencyMonitor : IDisposable
    {
        private readonly object gate = new object();
        private readonly Dictionary<string, LatencySample> latest = new Dictionary<string, LatencySample>();
        private readonly Dictionary<string, long> peerVersions = new Dictionary<string, long>();
        private string[] peers = new string[0];
        private CancellationTokenSource cancellation;
        private Task worker;
        private long epoch;
        private long sequence;
        private long peerVersion;
        private bool running;
        private bool disposed;

        private sealed class PeerTarget
        {
            internal string IP;
            internal long Version;
        }

        public void SetPeers(string[] addresses)
        {
            var values = new List<string>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            if (addresses != null)
            {
                foreach (string address in addresses)
                {
                    IPAddress parsed;
                    if (!IPAddress.TryParse(address, out parsed) || parsed.AddressFamily != AddressFamily.InterNetwork)
                        continue;
                    string ip = parsed.ToString();
                    if (seen.Add(ip)) values.Add(ip);
                    if (values.Count == 64) break;
                }
            }
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("LatencyMonitor");
                peers = values.ToArray();
                var remove = new List<string>();
                foreach (string ip in latest.Keys) if (!seen.Contains(ip)) remove.Add(ip);
                foreach (string ip in remove)
                {
                    latest.Remove(ip);
                    peerVersions.Remove(ip);
                }
                foreach (string ip in peers)
                    if (!latest.ContainsKey(ip))
                    {
                        peerVersions[ip] = ++peerVersion;
                        latest[ip] = new LatencySample(ip, "pending", null,
                            DateTimeOffset.MinValue, ++sequence, String.Empty);
                    }
            }
        }

        public void Start()
        {
            CancellationTokenSource old;
            lock (gate)
            {
                if (disposed) throw new ObjectDisposedException("LatencyMonitor");
                if (running) return;
                old = cancellation;
                var source = new CancellationTokenSource();
                cancellation = source;
                long version = ++epoch;
                running = true;
                foreach (string ip in peers)
                    latest[ip] = new LatencySample(ip, "pending", null, DateTimeOffset.MinValue, ++sequence, String.Empty);
                Task previous = worker;
                worker = Task.Run(async delegate
                {
                    if (previous != null)
                    {
                        try { await previous.ConfigureAwait(false); }
                        catch { }
                    }
                    try { await RunAsync(version, source.Token).ConfigureAwait(false); }
                    finally { source.Dispose(); }
                });
            }
            Cancel(old);
        }

        public LatencySample[] ReadLatest()
        {
            lock (gate)
            {
                var result = new LatencySample[peers.Length];
                for (int i = 0; i < peers.Length; ++i) result[i] = latest[peers[i]];
                return result;
            }
        }

        public void Stop()
        {
            CancellationTokenSource old;
            lock (gate)
            {
                old = cancellation;
                cancellation = null;
                ++epoch;
                running = false;
                foreach (string ip in peers)
                {
                    LatencySample value = latest[ip];
                    latest[ip] = new LatencySample(ip, "stopped", null, value.Time, ++sequence, String.Empty);
                }
            }
            Cancel(old);
        }

        public void Dispose()
        {
            lock (gate) { disposed = true; }
            Stop();
        }

        private static void Cancel(CancellationTokenSource source)
        {
            if (source == null) return;
            ThreadPool.QueueUserWorkItem(delegate(object state)
            {
                try { ((CancellationTokenSource)state).Cancel(); }
                catch (ObjectDisposedException) { }
            }, source);
        }

        private async Task RunAsync(long version, CancellationToken token)
        {
            using (var slots = new SemaphoreSlim(8, 8))
            {
                while (!token.IsCancellationRequested)
                {
                    var clock = Stopwatch.StartNew();
                    PeerTarget[] current;
                    lock (gate)
                    {
                        current = new PeerTarget[peers.Length];
                        for (int i = 0; i < peers.Length; ++i)
                            current[i] = new PeerTarget { IP = peers[i], Version = peerVersions[peers[i]] };
                    }
                    var queries = new List<Task>();
                    foreach (PeerTarget target in current)
                        queries.Add(ProbeAsync(target, version, token, slots));
                    try { await Task.WhenAll(queries.ToArray()).ConfigureAwait(false); }
                    catch (OperationCanceledException) { break; }
                    catch { }
                    int delay = Math.Max(0, 1000 - (int)Math.Min(clock.ElapsedMilliseconds, 1000));
                    try { await Task.Delay(delay, token).ConfigureAwait(false); }
                    catch (OperationCanceledException) { break; }
                }
            }
        }

        private async Task ProbeAsync(PeerTarget target, long version, CancellationToken token, SemaphoreSlim slots)
        {
            string ip = target.IP;
            await slots.WaitAsync(token).ConfigureAwait(false);
            try
            {
                if (token.IsCancellationRequested) return;
                string status = "error";
                string error = String.Empty;
                long? rtt = null;
                using (var ping = new Ping())
                {
                    try
                    {
                        PingReply reply = await ping.SendPingAsync(IPAddress.Parse(ip), 1000,
                            new byte[16], new PingOptions(64, true)).ConfigureAwait(false);
                        if (reply.Status == IPStatus.Success) { status = "success"; rtt = reply.RoundtripTime; }
                        else if (reply.Status == IPStatus.TimedOut) status = "timeout";
                        else status = "unreachable";
                    }
                    catch (PingException ex)
                    {
                        var socket = ex.InnerException as SocketException;
                        error = socket == null ? "ping_failed" : "ping_failed_" +
                            socket.NativeErrorCode.ToString(CultureInfo.InvariantCulture);
                    }
                    catch (SocketException ex)
                    {
                        error = "ping_failed_" + ex.NativeErrorCode.ToString(CultureInfo.InvariantCulture);
                    }
                    catch { error = "ping_failed"; }
                }
                lock (gate)
                {
                    long currentVersion;
                    if (version != epoch || !running || token.IsCancellationRequested ||
                        !peerVersions.TryGetValue(ip, out currentVersion) || currentVersion != target.Version) return;
                    latest[ip] = new LatencySample(ip, status, rtt, DateTimeOffset.UtcNow, ++sequence, error);
                }
            }
            finally { slots.Release(); }
        }
    }
}
