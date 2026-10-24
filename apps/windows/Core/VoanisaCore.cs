using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Voanisa.Windows.Core;

/// <summary>Raw C ABI exported by <c>Rust/voanisa-ffi</c> (voanisa_ffi.dll).</summary>
internal static class Native
{
    private const string Lib = "voanisa_ffi";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr voanisa_tracks_json(IntPtr path, IntPtr query);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void voanisa_string_free(IntPtr value);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr voanisa_decoder_open(IntPtr path);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr voanisa_decoder_open_error_json(IntPtr path);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr voanisa_decoder_info_json(IntPtr handle);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern long voanisa_decoder_read(IntPtr handle, IntPtr samples, uint frames);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int voanisa_decoder_seek(IntPtr handle, double seconds);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern double voanisa_decoder_position(IntPtr handle);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void voanisa_decoder_close(IntPtr handle);
}

public sealed class Track
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    public double Duration { get; init; }
    public string FileName { get; init; } = "";
    public string? CoverFileName { get; init; }
    public ImageSource? Cover { get; init; }

    public string DurationText
    {
        get
        {
            if (double.IsNaN(Duration) || Duration < 0) return "0:00";
            var total = (int)Duration;
            return $"{total / 60}:{total % 60:00}";
        }
    }
}

/// <summary>Thin, typed wrapper over the Rust core. No UI types except the cover image.</summary>
public static class VoanisaCore
{
    public static string LibraryRoot
    {
        get
        {
            var overridePath = Environment.GetEnvironmentVariable("VOANISA_LIBRARY");
            if (!string.IsNullOrEmpty(overridePath)) return overridePath;
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Music",
                "Voanisa");
        }
    }

    public static string DatabasePath => Path.Combine(LibraryRoot, "library.sqlite");
    public static string MediaDirectory => Path.Combine(LibraryRoot, "Media");
    public static string CoverDirectory => Path.Combine(LibraryRoot, "Covers", "Rendered");

    public static List<Track> ListTracks()
    {
        var path = Marshal.StringToCoTaskMemUTF8(DatabasePath);
        try
        {
            var raw = Native.voanisa_tracks_json(path, IntPtr.Zero);
            if (raw == IntPtr.Zero) return new List<Track>();
            try
            {
                var json = Marshal.PtrToStringUTF8(raw) ?? "";
                return ParseTracks(json);
            }
            finally
            {
                Native.voanisa_string_free(raw);
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(path);
        }
    }

    private static List<Track> ParseTracks(string json)
    {
        var tracks = new List<Track>();
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        if (!root.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
        {
            var message = root.TryGetProperty("error", out var error)
                && error.TryGetProperty("message", out var text)
                ? text.GetString()
                : "读取曲库失败";
            throw new InvalidOperationException(message);
        }

        if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
            return tracks;

        foreach (var item in data.EnumerateArray())
        {
            var coverFileName = item.TryGetProperty("cover_file_name", out var cover)
                && cover.ValueKind == JsonValueKind.String
                ? cover.GetString()
                : null;

            tracks.Add(new Track
            {
                Id = item.GetProperty("id").GetString() ?? "",
                Title = item.GetProperty("title").GetString() ?? "",
                Artist = item.TryGetProperty("artist", out var artist) ? artist.GetString() ?? "" : "",
                Album = item.TryGetProperty("album", out var album) ? album.GetString() ?? "" : "",
                Duration = item.TryGetProperty("duration", out var duration) ? duration.GetDouble() : 0,
                FileName = item.GetProperty("file_name").GetString() ?? "",
                CoverFileName = coverFileName,
                Cover = LoadCover(coverFileName)
            });
        }
        return tracks;
    }

    private static ImageSource? LoadCover(string? coverFileName)
    {
        if (string.IsNullOrEmpty(coverFileName)) return null;
        var path = Path.Combine(CoverDirectory, coverFileName);
        if (!File.Exists(path)) return null;
        try
        {
            return new BitmapImage(new Uri(path));
        }
        catch
        {
            return null;
        }
    }
}
