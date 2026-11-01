// Sample-level audio checks for review-video.ps1, compiled at run time with Add-Type.
// ffmpeg decodes the audio to raw 32-bit float PCM; this code reads it as a stream, so long
// videos never have to fit in memory. Written for C# 5 (the compiler in Windows PowerShell 5.1).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace VideoReview
{
    public class AudioEvent
    {
        public double Time;      // seconds from the start
        public double Level;     // dBFS of the jump (clicks) or of the sample (clipping)
        public double Ratio;     // clicks: how many times larger than the surrounding signal
        public int Channel;      // 0 = left, 1 = right
    }

    public class AudioScanResult
    {
        public double Duration;
        public long Samples;
        public double SamplePeakDb;
        public double SamplePeakTime;
        public double[] WindowPeakDb;      // peak level of every 100 ms window
        public float[] Envelope;           // RMS of every 10 ms frame (mono mix), for matching narration
        public List<AudioEvent> Clicks = new List<AudioEvent>();
        public List<AudioEvent> Clipping = new List<AudioEvent>();
        public long ClippedSamples;
    }

    public class MatchResult
    {
        public int Index;     // envelope frame (10 ms) where the clip starts
        public double Score;  // Pearson correlation, -1..1
    }

    public class FrameMatch
    {
        public int Index;     // closest frame in the other set, or -1
        public int Changed;   // pixels that differ by more than the tolerance
    }

    // Compares frame signatures (small greyscale thumbnails of equal size, one byte per pixel) to
    // find what changed between two renders.
    public static class FrameDiff
    {
        public static FrameMatch[] Closest(byte[][] frames, byte[][] others, int tolerance)
        {
            var result = new FrameMatch[frames.Length];
            for (int i = 0; i < frames.Length; i++)
            {
                var best = new FrameMatch { Index = -1, Changed = int.MaxValue };
                byte[] a = frames[i];
                for (int j = 0; j < others.Length; j++)
                {
                    byte[] b = others[j];
                    if (b.Length != a.Length) continue;
                    int n = 0;
                    for (int k = 0; k < a.Length && n < best.Changed; k++)
                        if (Math.Abs(a[k] - b[k]) > tolerance) n++;
                    if (n < best.Changed) { best.Changed = n; best.Index = j; }
                }
                result[i] = best;
            }
            return result;
        }
    }

    public static class AudioScan
    {
        public const int Rate = 48000;
        public const int EnvFrame = 480;          // 10 ms at 48 kHz
        const int PeakWindow = 4800;              // 100 ms
        public static int Margin = 96;            // 2 ms each side: the "surrounding signal" for clicks
        public static int Core = 2;               // samples either side of a candidate left out of that
        const int Block = 48000;

        static Process StartFfmpeg(string ffmpeg, string args)
        {
            var psi = new ProcessStartInfo(ffmpeg, args);
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            var p = Process.Start(psi);
            return p;
        }

        static string Quote(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }

        // Reads exactly what ffmpeg wrote and throws, with ffmpeg's own message, if it failed.
        static void Finish(Process p, System.Threading.Tasks.Task<string> err, string what)
        {
            p.WaitForExit();
            string e = err.Result;
            if (p.ExitCode != 0)
                throw new Exception("ffmpeg failed while " + what + " (exit " + p.ExitCode + "): " + e.Trim());
        }

        static int ReadFull(Stream s, byte[] b, int count)
        {
            int got = 0;
            while (got < count)
            {
                int n = s.Read(b, got, count - got);
                if (n <= 0) break;
                got += n;
            }
            return got;
        }

        static double Db(double v) { return v > 0 ? 20.0 * Math.Log10(v) : double.NegativeInfinity; }

        // channels: 1 for a mono source, otherwise 2 (ffmpeg downmixes anything wider to stereo).
        public static AudioScanResult Analyze(string ffmpeg, string input, int channels, double clickRatio, double clickMinDb, double clipDb)
        {
            int C = channels == 1 ? 1 : 2;
            double clickMin = Math.Pow(10, clickMinDb / 20.0);
            double clipLin = Math.Pow(10, clipDb / 20.0);
            var res = new AudioScanResult();
            var peaks = new List<double>();
            var env = new List<float>();
            var clicks = new List<AudioEvent>();

            string args = "-v error -nostdin -i " + Quote(input) + " -vn -map 0:a:0 -ac " + C + " -ar " + Rate + " -f f32le -";
            Process p = StartFfmpeg(ffmpeg, args);
            var err = p.StandardError.ReadToEndAsync();
            Stream s = p.StandardOutput.BaseStream;

            int pre = Margin + 2;                       // zero history before the first sample
            int cap = pre + Block + Margin + 2;
            var x = new float[C][];
            var e2 = new double[C][];
            var ps = new double[C][];
            for (int c = 0; c < C; c++) { x[c] = new float[cap]; e2[c] = new double[cap]; ps[c] = new double[cap + 1]; }
            long baseIdx = -pre;                        // absolute sample index of x[c][0]
            int fill = pre;
            byte[] raw = new byte[Block * C * 4];
            bool eof = false;
            double peak = 0; long peakAt = 0;
            double winPeak = 0; int winCount = 0;
            double envSum = 0; int envCount = 0;
            long total = 0;
            AudioEvent lastClick = null, lastClip = null;

            while (!eof)
            {
                int want = Math.Min(Block, cap - fill);
                int got = ReadFull(s, raw, want * C * 4);
                int frames = got / (C * 4);
                if (got < want * C * 4) eof = true;
                for (int i = 0; i < frames; i++)
                    for (int c = 0; c < C; c++)
                        x[c][fill + i] = BitConverter.ToSingle(raw, (i * C + c) * 4);
                fill += frames;
                total += frames;

                // Second difference: tiny for speech and music at 48 kHz, large for a click or a step.
                for (int c = 0; c < C; c++)
                {
                    var xc = x[c]; var ec = e2[c]; var pc = ps[c];
                    pc[0] = 0; pc[1] = 0; pc[2] = 0;
                    for (int i = 2; i < fill; i++)
                    {
                        double d = xc[i] - 2.0 * xc[i - 1] + xc[i - 2];
                        ec[i] = d * d;
                        pc[i + 1] = pc[i] + ec[i];
                    }
                }

                int end = eof ? fill : fill - Margin;
                for (int i = pre; i < end; i++)
                {
                    long abs = baseIdx + i;
                    double mono = 0;
                    for (int c = 0; c < C; c++)
                    {
                        double v = x[c][i];
                        double a = Math.Abs(v);
                        mono += v;
                        if (a > peak) { peak = a; peakAt = abs; }
                        if (a > winPeak) winPeak = a;
                        if (a >= clipLin)
                        {
                            res.ClippedSamples++;
                            double t = abs / (double)Rate;
                            if (lastClip == null || t - lastClip.Time > 0.05)
                            {
                                lastClip = new AudioEvent { Time = t, Level = Db(a), Channel = c };
                                res.Clipping.Add(lastClip);
                            }
                            else if (Db(a) > lastClip.Level) lastClip.Level = Db(a);
                        }

                        double ei = e2[c][i];
                        double ea = Math.Sqrt(ei);
                        if (ea >= clickMin)
                        {
                            int lo = i - Margin, hi = Math.Min(i + Margin, fill - 1);
                            int clo = i - Core, chi = Math.Min(i + Core, fill - 1);
                            double sum = (ps[c][hi + 1] - ps[c][lo]) - (ps[c][chi + 1] - ps[c][clo]);
                            int n = (hi - lo + 1) - (chi - clo + 1);
                            double local = n > 0 ? sum / n : 0;
                            double ratio = Math.Sqrt(ei / Math.Max(local, 1e-14));
                            if (ratio >= clickRatio)
                            {
                                double t = abs / (double)Rate;
                                if (lastClick != null && t - lastClick.Time <= 0.02)
                                {
                                    if (ratio > lastClick.Ratio) { lastClick.Ratio = ratio; lastClick.Level = Db(ea); lastClick.Channel = c; }
                                }
                                else
                                {
                                    lastClick = new AudioEvent { Time = t, Level = Db(ea), Ratio = ratio, Channel = c };
                                    clicks.Add(lastClick);
                                }
                            }
                        }
                    }
                    mono /= C;
                    envSum += mono * mono; envCount++;
                    if (envCount == EnvFrame) { env.Add((float)Math.Sqrt(envSum / EnvFrame)); envSum = 0; envCount = 0; }
                    winCount++;
                    if (winCount == PeakWindow) { peaks.Add(Db(winPeak)); winPeak = 0; winCount = 0; }
                }

                if (!eof)
                {
                    // Keep the samples the next block needs for its history and margins.
                    int keep = pre + Margin;
                    int from = fill - keep;
                    for (int c = 0; c < C; c++) Array.Copy(x[c], from, x[c], 0, keep);
                    baseIdx += from;
                    fill = keep;
                }
            }
            if (envCount > 0) env.Add((float)Math.Sqrt(envSum / envCount));
            if (winCount > 0) peaks.Add(Db(winPeak));
            Finish(p, err, "decoding the audio of " + input);
            if (total == 0) throw new Exception("ffmpeg returned no audio samples for " + input);

            res.Samples = total;
            res.Duration = total / (double)Rate;
            res.SamplePeakDb = Db(peak);
            res.SamplePeakTime = peakAt / (double)Rate;
            res.WindowPeakDb = peaks.ToArray();
            res.Envelope = env.ToArray();
            res.Clicks = clicks;
            return res;
        }

        // 10 ms RMS envelope of part of a file (mono), for matching a narration clip against the video.
        public static float[] Envelope(string ffmpeg, string input, double start, double length)
        {
            string args = "-v error -nostdin";
            if (start > 0) args += " -ss " + start.ToString(System.Globalization.CultureInfo.InvariantCulture);
            args += " -i " + Quote(input);
            if (length > 0) args += " -t " + length.ToString(System.Globalization.CultureInfo.InvariantCulture);
            args += " -vn -map 0:a:0 -ac 1 -ar " + Rate + " -f f32le -";
            Process p = StartFfmpeg(ffmpeg, args);
            var err = p.StandardError.ReadToEndAsync();
            Stream s = p.StandardOutput.BaseStream;
            var env = new List<float>();
            byte[] raw = new byte[EnvFrame * 4];
            while (true)
            {
                int got = ReadFull(s, raw, raw.Length);
                int n = got / 4;
                if (n == 0) break;
                double sum = 0;
                for (int i = 0; i < n; i++) { double v = BitConverter.ToSingle(raw, i * 4); sum += v * v; }
                env.Add((float)Math.Sqrt(sum / n));
                if (got < raw.Length) break;
            }
            Finish(p, err, "reading " + input);
            return env.ToArray();
        }

        // Finds where clip best lines up with video, searching start frames from..to (inclusive).
        public static MatchResult FindBest(float[] video, float[] clip, int from, int to)
        {
            var r = new MatchResult { Index = -1, Score = -2 };
            int L = clip.Length;
            if (L < 2 || video.Length < L) return r;
            from = Math.Max(0, from);
            to = Math.Min(to, video.Length - L);
            if (to < from) return r;
            double cm = 0; for (int j = 0; j < L; j++) cm += clip[j]; cm /= L;
            double cv = 0; var cz = new double[L];
            for (int j = 0; j < L; j++) { cz[j] = clip[j] - cm; cv += cz[j] * cz[j]; }
            if (cv <= 1e-18) return r;
            var pre = new double[video.Length + 1]; var pre2 = new double[video.Length + 1];
            for (int k = 0; k < video.Length; k++) { pre[k + 1] = pre[k] + video[k]; pre2[k + 1] = pre2[k] + (double)video[k] * video[k]; }
            for (int k = from; k <= to; k++)
            {
                double vs = pre[k + L] - pre[k];
                double vv = (pre2[k + L] - pre2[k]) - vs * vs / L;
                if (vv <= 1e-18) continue;
                double dot = 0;
                for (int j = 0; j < L; j++) dot += cz[j] * video[k + j];
                double score = dot / Math.Sqrt(cv * vv);
                if (score > r.Score) { r.Score = score; r.Index = k; }
            }
            return r;
        }
    }
}
