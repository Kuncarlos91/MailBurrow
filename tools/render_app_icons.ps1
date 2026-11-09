# Render the reviewed vector geometry with Windows' built-in drawing library.
# No downloads, Python imaging packages or app dependencies are required.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path $PSScriptRoot -Parent
$design = Get-Content -LiteralPath (Join-Path $projectRoot 'assets/branding/icon-design.json') -Raw | ConvertFrom-Json
$background = [System.Drawing.ColorTranslator]::FromHtml($design.background)
function New-ShapePath([string]$data) {
    $tokens = [regex]::Matches($data, '[MLCZ]|-?\d+(?:\.\d+)?')
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $index = 0
    $x = [single]0
    $y = [single]0
    while ($index -lt $tokens.Count) {
        $command = $tokens[$index].Value
        $index++
        if ($command -eq 'Z') { $path.CloseFigure(); continue }
        $count = if ($command -eq 'C') { 6 } else { 2 }
        $values = @()
        for ($j=0; $j -lt $count; $j++) {
            $values += [single]::Parse($tokens[$index].Value, [Globalization.CultureInfo]::InvariantCulture)
            $index++
        }
        switch ($command) {
            'M' { $path.StartFigure(); $x=$values[0]; $y=$values[1] }
            'L' { $path.AddLine($x,$y,$values[0],$values[1]); $x=$values[0]; $y=$values[1] }
            'C' { $path.AddBezier($x,$y,$values[0],$values[1],$values[2],$values[3],$values[4],$values[5]); $x=$values[4]; $y=$values[5] }
            default { throw 'Unsupported vector command' }
        }
    }
    return $path
}
$arch = New-ShapePath $design.arch
$body = New-ShapePath $design.body
$flap = New-ShapePath $design.flap
$master = [System.Drawing.Bitmap]::new(2048,2048,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [System.Drawing.Graphics]::FromImage($master)
$graphics.Clear($background)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.ScaleTransform(2.048,2.048)
$pen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml($design.arch_color),[single]$design.arch_width)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$brush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($design.envelope_color))
$graphics.DrawPath($pen,$arch)
$graphics.FillPath($brush,$body)
$graphics.FillPath($brush,$flap)
$graphics.Dispose()
function Save-Icon([int]$size,[string]$destination,[bool]$rgba=$false) {
    $format = if ($rgba) { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb } else { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb }
    $image = [System.Drawing.Bitmap]::new($size,$size,$format)
    $g = [System.Drawing.Graphics]::FromImage($image)
    $g.Clear($background)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($master,0,0,$size,$size)
    $g.Dispose()
    $image.Save($destination,[System.Drawing.Imaging.ImageFormat]::Png)
    $image.Dispose()
}
$catalogPath = Join-Path $projectRoot 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
$catalog = Get-Content -LiteralPath (Join-Path $catalogPath 'Contents.json') -Raw | ConvertFrom-Json
foreach ($entry in $catalog.images) {
    $size = [double]::Parse(($entry.size -split 'x')[0],[Globalization.CultureInfo]::InvariantCulture) * [double](($entry.scale -replace 'x',''))
    Save-Icon ([int]$size) (Join-Path $catalogPath $entry.filename)
}
$densities = @{mdpi=48;hdpi=72;xhdpi=96;xxhdpi=144;xxxhdpi=192}
foreach ($density in $densities.Keys) {
    Save-Icon $densities[$density] (Join-Path $projectRoot "android/app/src/main/res/mipmap-$density/ic_launcher.png")
}
Save-Icon 1024 (Join-Path $projectRoot 'assets/branding/store-icon-1024.png')
Save-Icon 512 (Join-Path $projectRoot 'assets/branding/store-icon-512.png') $true
$previewPath = Join-Path $projectRoot 'build/branding'
[IO.Directory]::CreateDirectory($previewPath) | Out-Null
$sheet = [System.Drawing.Bitmap]::new(1000,580,[System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::FromArgb(246,245,250))
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$font = [System.Drawing.Font]::new('Segoe UI',16)
$labelBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(40,30,60))
$g.DrawString('MailBurrow - selected A, vector refinement',$font,$labelBrush,24,18)
$g.DrawImage($master,24,72,256,256)
$g.DrawString('Square master',$font,$labelBrush,24,342)
$state=$g.Save()
$mask=[System.Drawing.Drawing2D.GraphicsPath]::new()
$mask.AddEllipse(364,72,256,256)
$g.SetClip($mask)
$g.DrawImage($master,364,72,256,256)
$g.Restore($state)
$mask.Dispose()
$g.DrawString('Circle preview',$font,$labelBrush,364,342)
$state=$g.Save()
$mask=[System.Drawing.Drawing2D.GraphicsPath]::new()
$mask.AddArc(704,72,64,64,180,90)
$mask.AddArc(896,72,64,64,270,90)
$mask.AddArc(896,264,64,64,0,90)
$mask.AddArc(704,264,64,64,90,90)
$mask.CloseFigure()
$g.SetClip($mask)
$g.DrawImage($master,704,72,256,256)
$g.Restore($state)
$mask.Dispose()
$g.DrawString('Rounded preview',$font,$labelBrush,704,342)
$x=24
foreach ($size in @(64,48,32)) {
    $g.DrawImage($master,$x,420,$size,$size)
    $g.DrawString("$size px",$font,$labelBrush,$x,500)
    $x+=130
}
$g.DrawString('Opaque PNGs; masks shown only for review.',$font,$labelBrush,430,438)
$g.Dispose()
$sheet.Save((Join-Path $previewPath 'mailburrow-icon-review.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()
$font.Dispose()
$labelBrush.Dispose()
$master.Dispose()
$arch.Dispose()
$body.Dispose()
$flap.Dispose()
$pen.Dispose()
$brush.Dispose()
Write-Output 'Rendered 15 unique iOS catalog files, five legacy Android sizes, two store exports and review sheet.'
