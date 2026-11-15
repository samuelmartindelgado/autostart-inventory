#Requires -Version 5.1
<#
.SYNOPSIS
    Inventario de solo lectura de todo lo que arranca automáticamente en Windows.

.DESCRIPTION
    Enumera las claves Run/RunOnce del registro, las carpetas de Inicio, las tareas
    programadas con disparador de arranque o de inicio de sesión, los servicios
    automáticos y los consumidores de eventos WMI. Para cada entrada obtiene la
    firma digital del ejecutable y calcula marcas de riesgo, de modo que un técnico
    vea de un vistazo qué se ejecuta solo y qué resulta raro.

    La herramienta es de SOLO LECTURA: no modifica, deshabilita ni borra nada.

.PARAMETER OutputPath
    Carpeta donde se escriben autostart.json, autostart.csv y report.html.
    Por defecto, el directorio actual.

.PARAMETER OnlySuspicious
    Muestra y escribe únicamente las entradas que tienen alguna marca.

.PARAMETER IncludeMicrosoft
    Incluye las entradas firmadas por Microsoft y las tareas de la carpeta
    \Microsoft\ (por defecto se ocultan).

.EXAMPLE
    .\Get-AutostartInventory.ps1 -OutputPath .\salida

    Genera el inventario completo en .\salida y devuelve 1 si hay entradas marcadas.

.EXAMPLE
    .\Get-AutostartInventory.ps1 -OnlySuspicious -IncludeMicrosoft

    Muestra solo las entradas marcadas, incluidas las de Microsoft.

.NOTES
    Requiere Windows PowerShell 5.1 o PowerShell 7. No necesita permisos de
    administrador: los orígenes que no se puedan leer se omiten y se avisa.
    Código de salida: 0 si no hay marcas, 1 si hay alguna entrada marcada.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Get-Location).Path,

    [switch]$OnlySuspicious,

    [switch]$IncludeMicrosoft
)

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'lib\AutostartInventory.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

# ---------------------------------------------------------------------------
# Recogida de entradas (cada origen se aísla para que un fallo no tumbe el resto)
# ---------------------------------------------------------------------------

$sources = @(
    @{ Nombre = 'Claves de registro'; Accion = { Get-RunKeyEntries } }
    @{ Nombre = 'Carpetas de Inicio'; Accion = { Get-StartupFolderEntries } }
    @{ Nombre = 'Tareas programadas'; Accion = { Get-TaskEntries -IncludeMicrosoft:$IncludeMicrosoft } }
    @{ Nombre = 'Servicios'; Accion = { Get-ServiceEntries } }
    @{ Nombre = 'Suscripciones WMI'; Accion = { Get-WmiPersistenceEntries } }
)

$allEntries = New-Object System.Collections.Generic.List[object]
$notes = New-Object System.Collections.Generic.List[string]

foreach ($source in $sources) {
    try {
        $items = @(& $source.Accion)
    }
    catch {
        $notes.Add(('{0}: no se pudieron leer ({1})' -f $source.Nombre, $_.Exception.Message))
        continue
    }

    foreach ($item in $items) {
        if ($null -ne $item) {
            $allEntries.Add($item)
        }
    }

    if ($items.Count -eq 0) {
        $notes.Add(('{0}: sin entradas' -f $source.Nombre))
    }
}

# ---------------------------------------------------------------------------
# Filtros
# ---------------------------------------------------------------------------

$hiddenMicrosoft = 0
$visible = New-Object System.Collections.Generic.List[object]

# Firmantes exactos de Microsoft (no basta con que el nombre "contenga" Microsoft).
$microsoftSigners = @('Microsoft Windows', 'Microsoft Corporation', 'Microsoft Windows Publisher')

foreach ($entry in $allEntries) {
    $isMicrosoft = ($entry.Firma -eq 'Firmado' -and $microsoftSigners -contains [string]$entry.Firmante)
    $hasMarks = -not [string]::IsNullOrWhiteSpace([string]$entry.Marcas)

    # Solo se oculta lo de Microsoft SIN marcas: un powershell.exe o rundll32.exe
    # firmado por Microsoft que lanza otra cosa se muestra siempre.
    if (-not $IncludeMicrosoft -and $isMicrosoft -and -not $hasMarks) {
        $hiddenMicrosoft++
        continue
    }

    if ($OnlySuspicious -and -not $hasMarks) {
        continue
    }

    $visible.Add($entry)
}

$marked = @($allEntries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Marcas) })
$visibleArray = $visible.ToArray()

# ---------------------------------------------------------------------------
# Archivos de salida
# ---------------------------------------------------------------------------

$jsonPath = Join-Path -Path $OutputPath -ChildPath 'autostart.json'
$csvPath = Join-Path -Path $OutputPath -ChildPath 'autostart.csv'
$htmlPath = Join-Path -Path $OutputPath -ChildPath 'report.html'
$outputWritten = $true

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
    }

    if ($visibleArray.Count -gt 0) {
        $json = ConvertTo-Json -InputObject $visibleArray -Depth 4
        # Evita que Excel interprete como fórmula un texto que empiece por = + - @
        # (un nombre de entrada lo controla quien la creó).
        $csvRows = foreach ($row in $visibleArray) {
            $copy = [ordered]@{}
            foreach ($property in $row.PSObject.Properties) {
                $value = [string]$property.Value
                if ($value -match '^[=+\-@\t\r]') {
                    $value = "'" + $value
                }
                $copy[$property.Name] = $value
            }
            [pscustomobject]$copy
        }
        $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }
    else {
        $json = '[]'
        $header = '"Origen","Ubicacion","Nombre","Comando","Ejecutable","Firma","Firmante","Marcas"'
        [System.IO.File]::WriteAllText($csvPath, $header + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($true))
    }

    [System.IO.File]::WriteAllText($jsonPath, $json, [System.Text.UTF8Encoding]::new($false))
    ConvertTo-AutostartHtml -Entries $visibleArray -Path $htmlPath -ErrorAction Stop
}
catch {
    $outputWritten = $false
    Write-Warning ('No se pudieron escribir los archivos de salida en ''{0}'': {1}' -f $OutputPath, $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# Resumen en consola (único punto con Write-Host)
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ('Inventario de arranque automático · {0} · {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
Write-Host ('Entradas: {0} | Mostradas: {1} | Marcadas: {2}' -f $allEntries.Count, $visibleArray.Count, $marked.Count)

if ($hiddenMicrosoft -gt 0) {
    Write-Host ('Ocultas por firma de Microsoft: {0} (use -IncludeMicrosoft para verlas)' -f $hiddenMicrosoft) -ForegroundColor DarkGray
}


foreach ($note in $notes) {
    Write-Host ('Aviso: {0}' -f $note) -ForegroundColor Yellow
}

if ($visibleArray.Count -gt 0) {
    Write-Host ''
    $table = $visibleArray |
        Select-Object -Property Origen, Nombre, Firma, Marcas |
        Format-Table -AutoSize |
        Out-String -Width 220
    Write-Host $table
}
else {
    Write-Host 'No hay entradas que mostrar.' -ForegroundColor Green
}

if ($outputWritten) {
    Write-Host ('Informe HTML: {0}' -f $htmlPath) -ForegroundColor DarkGray
    Write-Host ('JSON: {0} | CSV: {1}' -f $jsonPath, $csvPath) -ForegroundColor DarkGray
}

if ($marked.Count -gt 0) {
    Write-Host ('Resultado: {0} entrada(s) marcada(s). Revise el informe antes de tocar nada.' -f $marked.Count) -ForegroundColor Yellow
    exit 1
}

Write-Host 'Resultado: sin entradas marcadas.' -ForegroundColor Green
exit 0
