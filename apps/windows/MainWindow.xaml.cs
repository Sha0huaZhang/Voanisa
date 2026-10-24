using System.Collections.ObjectModel;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Voanisa.Windows.Core;

namespace Voanisa.Windows;

public sealed partial class MainWindow : Window
{
    private readonly Player _player = new();
    private readonly ObservableCollection<Track> _tracks = new();
    private readonly DispatcherTimer _timer = new();
    private Track? _current;
    private bool _updatingSlider;

    public MainWindow()
    {
        InitializeComponent();

        Title = "Voanisa";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new SizeInt32(1100, 720));

        TrackList.ItemsSource = _tracks;

        _timer.Interval = TimeSpan.FromMilliseconds(200);
        _timer.Tick += (_, _) => UpdateProgress();

        Loaded += (_, _) => LoadLibrary();
        Closed += (_, _) => _player.Dispose();
    }

    private void LoadLibrary()
    {
        try
        {
            var tracks = VoanisaCore.ListTracks();
            _tracks.Clear();
            foreach (var track in tracks) _tracks.Add(track);
            CountText.Text = $"{tracks.Count} 首";
        }
        catch (Exception error)
        {
            CountText.Text = $"读取失败：{error.Message}";
        }
    }

    private void TrackList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is Track track) PlayTrack(track);
    }

    private void PlayTrack(Track track)
    {
        try
        {
            _player.Load(Path.Combine(VoanisaCore.MediaDirectory, track.FileName));
            _player.Play();

            _current = track;
            NowTitle.Text = track.Title;
            NowArtist.Text = track.Artist;
            PositionSlider.Maximum = Math.Max(_player.Duration, 0.1);
            DurationText.Text = Format(_player.Duration);
            SetPlayGlyph(playing: true);
            _timer.Start();
        }
        catch (Exception error)
        {
            NowTitle.Text = "播放失败";
            NowArtist.Text = error.Message;
        }
    }

    private void Play_Click(object sender, RoutedEventArgs e)
    {
        if (_current is null)
        {
            if (_tracks.Count > 0) PlayTrack(_tracks[0]);
            return;
        }

        if (_player.IsPlaying)
        {
            _player.Pause();
            SetPlayGlyph(playing: false);
        }
        else
        {
            _player.Play();
            SetPlayGlyph(playing: true);
        }
    }

    private void Prev_Click(object sender, RoutedEventArgs e) => Skip(-1);

    private void Next_Click(object sender, RoutedEventArgs e) => Skip(1);

    private void Skip(int offset)
    {
        if (_tracks.Count == 0) return;

        var index = _current is null ? -1 : _tracks.IndexOf(_current);
        var target = index + offset;
        if (target < 0 || target >= _tracks.Count) return;
        PlayTrack(_tracks[target]);
    }

    private void PositionSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (_updatingSlider || !_player.HasTrack) return;
        _player.Seek(e.NewValue);
    }

    private void UpdateProgress()
    {
        if (!_player.HasTrack) return;

        _updatingSlider = true;
        PositionSlider.Value = _player.Position;
        _updatingSlider = false;

        PositionText.Text = Format(_player.Position);
        DurationText.Text = Format(_player.Duration);
    }

    private void SetPlayGlyph(bool playing)
    {
        PlayButton.Content = new FontIcon
        {
            FontSize = 14,
            Glyph = playing ? "\uE769" : "\uE768"
        };
    }

    private static string Format(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) return "0:00";
        var total = (int)seconds;
        return $"{total / 60}:{total % 60:00}";
    }
}
