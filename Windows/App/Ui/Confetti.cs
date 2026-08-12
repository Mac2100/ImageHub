using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace ImageHub.Views;

/// <summary>
/// A short burst of confetti when a drive finishes.
///
/// Kept from the macOS app deliberately. A build is ten to forty minutes of watching a
/// progress bar, usually at the end of a long day of reimaging, and the moment it
/// works should be unmistakable from across a room. It runs for three seconds and then
/// removes itself, so nothing keeps animating behind a finished view.
/// </summary>
public sealed class Confetti : Canvas
{
    private sealed class Piece
    {
        public required Shape Shape { get; init; }

        public double X { get; set; }

        public double Y { get; set; }

        public double VelocityX { get; set; }

        public double VelocityY { get; set; }

        public double Spin { get; set; }

        public double Angle { get; set; }
    }

    private readonly List<Piece> _pieces = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Random _random;
    private int _frames;

    public Confetti(int seed, double width, double height)
    {
        _random = new Random(seed);
        Width = width;
        Height = height;
        IsHitTestVisible = false;
        ClipToBounds = true;

        Color[] palette =
        {
            ColorOf("AccentBrush"),
            ColorOf("AccentSecondaryBrush"),
            ColorOf("SuccessBrush"),
            ColorOf("WarningBrush"),
        };

        for (int i = 0; i < 70; i++)
        {
            bool round = _random.Next(2) == 0;
            double size = 5 + _random.NextDouble() * 6;
            Shape shape = round
                ? new Ellipse { Width = size, Height = size }
                : new Rectangle { Width = size, Height = size * 0.6, RadiusX = 1, RadiusY = 1 };
            shape.Fill = new SolidColorBrush(palette[_random.Next(palette.Length)]);
            shape.RenderTransformOrigin = new Point(0.5, 0.5);
            shape.RenderTransform = new RotateTransform(0);

            var piece = new Piece
            {
                Shape = shape,
                X = width * (0.15 + _random.NextDouble() * 0.7),
                Y = -10 - _random.NextDouble() * height * 0.4,
                VelocityX = (_random.NextDouble() - 0.5) * 2.2,
                VelocityY = 1.6 + _random.NextDouble() * 2.6,
                Spin = (_random.NextDouble() - 0.5) * 14,
            };
            _pieces.Add(piece);
            Children.Add(shape);
            SetLeft(shape, piece.X);
            SetTop(shape, piece.Y);
        }

        _timer.Tick += OnTick;
        _timer.Start();
    }

    private static Color ColorOf(string key) =>
        Ui.Brush(key) is SolidColorBrush solid ? solid.Color : Colors.SteelBlue;

    private void OnTick(object? sender, EventArgs e)
    {
        _frames++;
        // Roughly three seconds at 16 ms, then fade out over the last half second.
        if (_frames > 190)
        {
            Stop();
            return;
        }
        if (_frames > 160) { Opacity = Math.Max(0, (190 - _frames) / 30.0); }

        foreach (Piece piece in _pieces)
        {
            piece.VelocityY += 0.045;
            piece.X += piece.VelocityX;
            piece.Y += piece.VelocityY;
            piece.Angle += piece.Spin;
            SetLeft(piece.Shape, piece.X);
            SetTop(piece.Shape, piece.Y);
            if (piece.Shape.RenderTransform is RotateTransform rotate) { rotate.Angle = piece.Angle; }
        }
    }

    public void Stop()
    {
        _timer.Stop();
        _timer.Tick -= OnTick;
        Children.Clear();
        _pieces.Clear();
        if (Parent is Panel panel) { panel.Children.Remove(this); }
    }
}
