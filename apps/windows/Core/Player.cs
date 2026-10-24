using System.Runtime.InteropServices;
using System.Text.Json;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Voanisa.Windows.Core;

/// <summary>Pulls interleaved f32 from the Rust decoder, so every container plays
/// through exactly one decoding path (the same one macOS uses).</summary>
public sealed class RustAudioSource : ISampleProvider
{
    private readonly IntPtr _decoder;
    private float[] _buffer;

    public WaveFormat WaveFormat { get; }

    public RustAudioSource(IntPtr decoder, int sampleRate, int channels)
    {
        _decoder = decoder;
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, channels);
        _buffer = new float[4096 * channels];
    }

    public int Read(float[] buffer, int offset, int count)
    {
        var channels = WaveFormat.Channels;
        var frames = count / channels;
        if (frames <= 0) return 0;

        var needed = frames * channels;
        if (_buffer.Length < needed) _buffer = new float[needed];

        var handle = GCHandle.Alloc(_buffer, GCHandleType.Pinned);
        try
        {
            var read = Native.voanisa_decoder_read(
                _decoder,
                handle.AddrOfPinnedObject(),
                (uint)frames);

            if (read <= 0) return 0;
            Array.Copy(_buffer, 0, buffer, offset, (int)read);
            return (int)read;
        }
        finally
        {
            handle.Free();
        }
    }
}

/// <summary>WASAPI output for the Rust decoder.</summary>
public sealed class Player : IDisposable
{
    private WasapiOut? _output;
    private IntPtr _decoder = IntPtr.Zero;

    public double Duration { get; private set; }
    public bool IsPlaying => _output?.PlaybackState == PlaybackState.Playing;
    public double Position => _decoder == IntPtr.Zero ? 0 : Native.voanisa_decoder_position(_decoder);
    public bool HasTrack => _decoder != IntPtr.Zero;

    public void Load(string path)
    {
        Stop();

        var pointer = Marshal.StringToCoTaskMemUTF8(path);
        try
        {
            _decoder = Native.voanisa_decoder_open(pointer);
        }
        finally
        {
            Marshal.FreeCoTaskMem(pointer);
        }

        if (_decoder == IntPtr.Zero)
            throw new InvalidOperationException("无法解码这个文件");

        var (rate, channels, duration) = ReadInfo(_decoder);
        Duration = duration;

        ISampleProvider chain = new RustAudioSource(_decoder, rate, channels);
        if (rate != 48_000)
            chain = new WdlResamplingSampleProvider(chain, 48_000);

        _output = new WasapiOut(AudioClientShareMode.Shared, 200);
        _output.Init(chain.ToWaveProvider());
    }

    public void Play() => _output?.Play();
    public void Pause() => _output?.Pause();

    public void Seek(double seconds)
    {
        if (_decoder != IntPtr.Zero)
            Native.voanisa_decoder_seek(_decoder, seconds);
    }

    public void Stop()
    {
        _output?.Stop();
        _output?.Dispose();
        _output = null;

        if (_decoder != IntPtr.Zero)
        {
            Native.voanisa_decoder_close(_decoder);
            _decoder = IntPtr.Zero;
        }
    }

    public void Dispose() => Stop();

    private static (int Rate, int Channels, double Duration) ReadInfo(IntPtr decoder)
    {
        var raw = Native.voanisa_decoder_info_json(decoder);
        if (raw == IntPtr.Zero) throw new InvalidOperationException("解码器没有返回信息");

        try
        {
            var json = Marshal.PtrToStringUTF8(raw) ?? "";
            using var document = JsonDocument.Parse(json);
            var data = document.RootElement.GetProperty("data");
            return (
                data.GetProperty("sample_rate").GetInt32(),
                data.GetProperty("channels").GetInt32(),
                data.GetProperty("duration_seconds").GetDouble());
        }
        finally
        {
            Native.voanisa_string_free(raw);
        }
    }
}
