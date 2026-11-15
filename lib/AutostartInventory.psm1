# ============================================================================
#  AutostartInventory.psm1
#  Inventario de SOLO LECTURA de los programas que arrancan automáticamente
#  en Windows. Ninguna función de este módulo modifica, deshabilita ni borra
#  nada: únicamente lee el registro, carpetas, tareas, servicios y WMI.
# ============================================================================

# Cache de firmas por ruta (muchas entradas comparten ejecutable).
$script:SignatureCache = @{}

# Rutas que se consideran "escribibles por el usuario" y por tanto sospechosas.
$script:ScriptLaunchers = @(
    'powershell.exe',
    'pwsh.exe',
    'cmd.exe',
    'wscript.exe',
    'cscript.exe',
    'mshta.exe',
    'rundll32.exe',
    'regsvr32.exe'
)

function Get-EntryField {
    <#
    .SYNOPSIS
        Lee una propiedad de una entrada aceptando PSCustomObject o diccionario.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Entry,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) {
            return $Entry[$Name]
        }
        return $null
    }

    $property = $Entry.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function ConvertTo-HtmlText {
    <#
    .SYNOPSIS
        Codifica texto para insertarlo en HTML sin romper el documento.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Test-UserWritablePath {
    <#
    .SYNOPSIS
        Indica si una ruta está bajo el perfil del usuario, AppData, Temp o
        C:\Users\Public, donde cualquier proceso sin privilegios puede escribir.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalized = $Path.ToLowerInvariant().Replace('/', '\')

    $roots = @(
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA,
        $env:TEMP,
        $env:TMP,
        'C:\Users\Public'
    )

    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        $prefix = $root.ToLowerInvariant().Replace('/', '\').TrimEnd('\')
        if ($normalized -eq $prefix -or $normalized.StartsWith($prefix + '\')) {
            return $true
        }
    }

    if ($normalized -match '\\temp\\') {
        return $true
    }

    if ($normalized -match '\\appdata\\') {
        return $true
    }

    return $false
}

function Get-ExecutablePath {
    <#
    .SYNOPSIS
        Extrae la ruta del ejecutable de una línea de comandos.
    .DESCRIPTION
        Admite rutas entre comillas, rutas sin comillas terminadas en
        .exe/.cmd/.bat/.ps1/.vbs/.js, expande variables de entorno y resuelve
        el caso rundll32.exe <dll>,<función> devolviendo la DLL.
    .OUTPUTS
        System.String o $null si no hay nada reconocible.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }

    $line = $CommandLine.Trim()
    $executable = $null
    $rest = ''

    if ($line.StartsWith('"') -or $line.StartsWith("'")) {
        $quote = $line.Substring(0, 1)
        $end = $line.IndexOf($quote, 1)
        if ($end -gt 1) {
            $executable = $line.Substring(1, $end - 1)
            $rest = $line.Substring($end + 1).Trim()
        }
        else {
            $executable = $line.Trim($quote.ToCharArray())
        }
    }
    else {
        $pattern = '^(?<exe>.+?\.(?:exe|cmd|bat|ps1|vbs|js))(?=\s|$)'
        $match = [regex]::Match($line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $executable = $match.Groups['exe'].Value
            $rest = $line.Substring($match.Length).Trim()
        }
        else {
            $tokens = $line -split '\s+', 2
            $executable = $tokens[0]
            if ($tokens.Count -gt 1) {
                $rest = $tokens[1]
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($executable)) {
        return $null
    }

    $executable = [Environment]::ExpandEnvironmentVariables($executable.Trim().Trim('"'))
    if ([string]::IsNullOrWhiteSpace($executable)) {
        return $null
    }

    $leaf = [System.IO.Path]::GetFileName($executable)
    if ($leaf -eq 'rundll32.exe' -and -not [string]::IsNullOrWhiteSpace($rest)) {
        $target = ($rest.Trim().Trim('"') -split ',', 2)[0].Trim().Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            return [Environment]::ExpandEnvironmentVariables($target)
        }
    }

    return $executable
}

function Get-SignatureInfo {
    <#
    .SYNOPSIS
        Devuelve el estado de la firma digital de un archivo.
    .OUTPUTS
        PSCustomObject con Estado ('Firmado'|'Sin firma'|'Firma no válida'|'No existe')
        y Firmante (CN del certificado o cadena vacía).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    $result = [pscustomobject]@{
        Estado   = 'No existe'
        Firmante = ''
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $result
    }

    $cacheKey = $Path.ToLowerInvariant()
    if ($script:SignatureCache.ContainsKey($cacheKey)) {
        return $script:SignatureCache[$cacheKey]
    }

    # Un nombre suelto (pwsh.exe, cmd.exe) se resuelve contra el PATH.
    $resolvedPath = $Path
    if ($Path -notmatch '[\\/]') {
        $command = Get-Command -Name $Path -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            $resolvedPath = [string]$command.Source
            $cacheKey = $resolvedPath.ToLowerInvariant()
            if ($script:SignatureCache.ContainsKey($cacheKey)) {
                return $script:SignatureCache[$cacheKey]
            }
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $script:SignatureCache[$cacheKey] = $result
            return $result
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $resolvedPath -ErrorAction Stop
        if ($null -eq $signature) {
            $result.Estado = 'Sin firma'
        }
        else {
            switch ($signature.Status) {
                'Valid' { $result.Estado = 'Firmado' }
                'NotSigned' { $result.Estado = 'Sin firma' }
                'UnknownError' { $result.Estado = 'Sin firma' }
                'NotSupported' { $result.Estado = 'Sin firma' }
                default { $result.Estado = 'Firma no válida' }
            }

            if ($null -ne $signature.SignerCertificate) {
                $subject = [string]$signature.SignerCertificate.Subject
                $cn = [regex]::Match($subject, 'CN=([^,]+)')
                if ($cn.Success) {
                    $result.Firmante = $cn.Groups[1].Value.Trim()
                }
                elseif (-not [string]::IsNullOrWhiteSpace($subject)) {
                    $result.Firmante = $subject.Trim()
                }
            }
        }
    }
    catch {
        Write-Verbose ("No se pudo leer la firma de '{0}': {1}" -f $Path, $_.Exception.Message)
        $result.Estado = 'Sin firma'
    }

    $script:SignatureCache[$cacheKey] = $result
    return $result
}

function Get-EntryFlags {
    <#
    .SYNOPSIS
        Calcula las marcas de riesgo de una entrada del inventario.
    .OUTPUTS
        System.String[] con las marcas en español (vacío si no hay ninguna).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Entry
    )

    $flags = New-Object System.Collections.Generic.List[string]

    $firma = [string](Get-EntryField -Entry $Entry -Name 'Firma')
    $executable = [string](Get-EntryField -Entry $Entry -Name 'Ejecutable')
    $origen = [string](Get-EntryField -Entry $Entry -Name 'Origen')

    if ($firma -eq 'Sin firma') {
        $flags.Add('Sin firma')
    }

    if ($firma -eq 'Firma no válida') {
        $flags.Add('Firma no válida')
    }

    if ($firma -eq 'No existe' -and -not [string]::IsNullOrWhiteSpace($executable)) {
        $flags.Add('El ejecutable no existe')
    }

    if (-not [string]::IsNullOrWhiteSpace($executable)) {
        if (Test-UserWritablePath -Path $executable) {
            $flags.Add('Ejecutable en carpeta de usuario o Temp')
        }

        $leaf = [System.IO.Path]::GetFileName($executable).ToLowerInvariant()
        if ($script:ScriptLaunchers -contains $leaf) {
            $flags.Add('Lanzador de scripts')
        }
    }

    if ($origen -match 'WMI') {
        $flags.Add('Persistencia WMI')
    }

    return $flags.ToArray()
}

function New-AutostartEntry {
    <#
    .SYNOPSIS
        Construye una fila del inventario con firma, firmante y marcas.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Origen,

        [AllowEmptyString()]
        [string]$Ubicacion = '',

        [AllowEmptyString()]
        [string]$Nombre = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Comando = ''
    )

    $executable = Get-ExecutablePath -CommandLine $Comando
    $signature = Get-SignatureInfo -Path $executable

    $entry = [pscustomobject]@{
        Origen     = $Origen
        Ubicacion  = $Ubicacion
        Nombre     = $Nombre
        Comando    = $Comando
        Ejecutable = $executable
        Firma      = $signature.Estado
        Firmante   = $signature.Firmante
        Marcas     = ''
    }

    $entry.Marcas = (@(Get-EntryFlags -Entry $entry) -join '; ')
    return $entry
}

function Get-RunKeyEntries {
    <#
    .SYNOPSIS
        Enumera las claves Run y RunOnce de HKLM, HKCU y WOW6432Node.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $sources = @(
        [pscustomobject]@{ Ruta = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Origen = 'Registro Run' }
        [pscustomobject]@{ Ruta = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Origen = 'Registro RunOnce' }
        [pscustomobject]@{ Ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Origen = 'Registro Run' }
        [pscustomobject]@{ Ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Origen = 'Registro RunOnce' }
        [pscustomobject]@{ Ruta = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Origen = 'Registro Run' }
    )

    foreach ($source in $sources) {
        $key = $null
        try {
            if (-not (Test-Path -LiteralPath $source.Ruta)) {
                continue
            }

            $key = Get-Item -LiteralPath $source.Ruta -ErrorAction Stop
            foreach ($valueName in $key.GetValueNames()) {
                if ([string]::IsNullOrWhiteSpace($valueName)) {
                    continue
                }

                $value = [string]$key.GetValue($valueName)
                if ([string]::IsNullOrWhiteSpace($value)) {
                    continue
                }

                New-AutostartEntry -Origen $source.Origen -Ubicacion $source.Ruta -Nombre $valueName -Comando $value
            }
        }
        catch {
            Write-Verbose ("No se pudo leer '{0}': {1}" -f $source.Ruta, $_.Exception.Message)
        }
        finally {
            if ($null -ne $key) {
                $key.Close()
            }
        }
    }
}

function Get-StartupFolderEntries {
    <#
    .SYNOPSIS
        Enumera los accesos directos de las carpetas de Inicio común y del usuario.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $folders = New-Object System.Collections.Generic.List[string]

    try {
        $common = [Environment]::GetFolderPath('CommonStartup')
        if (-not [string]::IsNullOrWhiteSpace($common)) {
            $folders.Add($common)
        }
    }
    catch {
        Write-Verbose ("No se pudo localizar la carpeta Inicio común: {0}" -f $_.Exception.Message)
    }

    try {
        $user = [Environment]::GetFolderPath('Startup')
        if (-not [string]::IsNullOrWhiteSpace($user)) {
            $folders.Add($user)
        }
    }
    catch {
        Write-Verbose ("No se pudo localizar la carpeta Inicio del usuario: {0}" -f $_.Exception.Message)
    }

    $shell = $null
    try {
        $shell = New-Object -ComObject 'WScript.Shell'
    }
    catch {
        Write-Verbose ("No se pudo crear WScript.Shell; los .lnk se muestran sin resolver: {0}" -f $_.Exception.Message)
    }

    try {
        foreach ($folder in $folders) {
            try {
                if (-not (Test-Path -LiteralPath $folder)) {
                    continue
                }

                $files = Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop
            }
            catch {
                Write-Verbose ("No se pudo leer la carpeta Inicio '{0}': {1}" -f $folder, $_.Exception.Message)
                continue
            }

            foreach ($file in $files) {
                $command = $file.FullName
                if ($file.Extension -eq '.lnk' -and $null -ne $shell) {
                    $shortcut = $null
                    try {
                        $shortcut = $shell.CreateShortcut($file.FullName)
                        $targetPath = [string]$shortcut.TargetPath
                        if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                            $command = ('"{0}" {1}' -f $targetPath, [string]$shortcut.Arguments).Trim()
                        }
                    }
                    catch {
                        Write-Verbose ("No se pudo resolver el acceso directo '{0}': {1}" -f $file.FullName, $_.Exception.Message)
                    }
                    finally {
                        if ($null -ne $shortcut) {
                            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
                        }
                    }
                }

                New-AutostartEntry -Origen 'Carpeta Inicio' -Ubicacion $folder -Nombre $file.Name -Comando $command
            }
        }
    }
    finally {
        if ($null -ne $shell) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

function Get-TaskEntries {
    <#
    .SYNOPSIS
        Enumera tareas programadas con disparador de arranque o de inicio de sesión.
    .PARAMETER IncludeMicrosoft
        Incluye las tareas de la ruta \Microsoft\ (por defecto se omiten).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$IncludeMicrosoft
    )

    if ($null -eq (Get-Command -Name 'Get-ScheduledTask' -ErrorAction SilentlyContinue)) {
        Write-Verbose 'El módulo ScheduledTasks no está disponible; se omiten las tareas programadas.'
        return
    }

    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop
    }
    catch {
        Write-Verbose ("No se pudieron enumerar las tareas programadas: {0}" -f $_.Exception.Message)
        return
    }

    $bootTriggerClasses = @('MSFT_TaskBootTrigger', 'MSFT_TaskLogonTrigger')

    foreach ($task in $tasks) {
        try {
            $taskPath = [string]$task.TaskPath

            if (-not $IncludeMicrosoft -and $taskPath.StartsWith('\Microsoft\', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $hasStartupTrigger = $false
            foreach ($trigger in @($task.Triggers)) {
                if ($null -eq $trigger) {
                    continue
                }

                $className = ''
                $cimProperty = $trigger.PSObject.Properties['CimClass']
                if ($null -ne $cimProperty -and $null -ne $cimProperty.Value) {
                    $className = [string]$cimProperty.Value.CimClassName
                }

                if ($bootTriggerClasses -contains $className) {
                    $hasStartupTrigger = $true
                    break
                }
            }

            if (-not $hasStartupTrigger) {
                continue
            }

            foreach ($action in @($task.Actions)) {
                if ($null -eq $action) {
                    continue
                }

                $executeProperty = $action.PSObject.Properties['Execute']
                if ($null -eq $executeProperty) {
                    continue
                }

                $execute = [string]$executeProperty.Value
                if ([string]::IsNullOrWhiteSpace($execute)) {
                    continue
                }

                $arguments = ''
                $argumentsProperty = $action.PSObject.Properties['Arguments']
                if ($null -ne $argumentsProperty -and $null -ne $argumentsProperty.Value) {
                    $arguments = [string]$argumentsProperty.Value
                }

                $command = ($execute + ' ' + $arguments).Trim()
                New-AutostartEntry -Origen 'Tarea programada' -Ubicacion ($taskPath + [string]$task.TaskName) -Nombre ([string]$task.TaskName) -Comando $command
            }
        }
        catch {
            Write-Verbose ("No se pudo leer una tarea programada: {0}" -f $_.Exception.Message)
        }
    }
}

function Get-ServiceEntries {
    <#
    .SYNOPSIS
        Enumera los servicios Win32 cuyo modo de inicio es Automático.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    try {
        $services = Get-CimInstance -ClassName 'Win32_Service' -Filter "StartMode='Auto'" -ErrorAction Stop
    }
    catch {
        Write-Verbose ("No se pudieron enumerar los servicios: {0}" -f $_.Exception.Message)
        return
    }

    foreach ($service in $services) {
        try {
            $pathName = [string]$service.PathName
            if ([string]::IsNullOrWhiteSpace($pathName)) {
                continue
            }

            New-AutostartEntry -Origen 'Servicio' -Ubicacion 'Administrador de servicios' -Nombre ([string]$service.Name) -Comando $pathName
        }
        catch {
            Write-Verbose ("No se pudo leer un servicio: {0}" -f $_.Exception.Message)
        }
    }
}

function Get-WmiPersistenceEntries {
    <#
    .SYNOPSIS
        Enumera consumidores de eventos WMI (persistencia) en root\subscription.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    try {
        $consumers = Get-CimInstance -Namespace 'root/subscription' -ClassName '__EventConsumer' -ErrorAction Stop
    }
    catch {
        Write-Verbose ("No se pudo consultar root/subscription: {0}" -f $_.Exception.Message)
        return
    }

    $wantedClasses = @('CommandLineEventConsumer', 'ActiveScriptEventConsumer')

    foreach ($consumer in @($consumers)) {
        try {
            if ($null -eq $consumer) {
                continue
            }

            $className = ''
            $cimProperty = $consumer.PSObject.Properties['CimClass']
            if ($null -ne $cimProperty -and $null -ne $cimProperty.Value) {
                $className = [string]$cimProperty.Value.CimClassName
            }

            if ($wantedClasses -notcontains $className) {
                continue
            }

            $name = $className
            $nameProperty = $consumer.PSObject.Properties['Name']
            if ($null -ne $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
                $name = [string]$nameProperty.Value
            }

            if ($className -eq 'CommandLineEventConsumer') {
                $command = ''
                $commandProperty = $consumer.PSObject.Properties['CommandLineTemplate']
                if ($null -ne $commandProperty -and -not [string]::IsNullOrWhiteSpace([string]$commandProperty.Value)) {
                    $command = [string]$commandProperty.Value
                }
                else {
                    $executableProperty = $consumer.PSObject.Properties['ExecutablePath']
                    if ($null -ne $executableProperty) {
                        $command = [string]$executableProperty.Value
                    }
                }

                New-AutostartEntry -Origen 'WMI' -Ubicacion 'root\subscription' -Nombre $name -Comando $command
            }
            else {
                # Los consumidores de script no tienen un ejecutable: se marcan igualmente.
                $scriptProperty = $consumer.PSObject.Properties['ScriptText']
                $command = ''
                if ($null -ne $scriptProperty) {
                    $command = [string]$scriptProperty.Value
                }

                $entry = [pscustomobject]@{
                    Origen     = 'WMI'
                    Ubicacion  = 'root\subscription'
                    Nombre     = $name
                    Comando    = $command
                    Ejecutable = $null
                    Firma      = ''
                    Firmante   = ''
                    Marcas     = 'Persistencia WMI'
                }

                $entry
            }
        }
        catch {
            Write-Verbose ("No se pudo leer un consumidor WMI: {0}" -f $_.Exception.Message)
        }
    }
}

function ConvertTo-AutostartHtml {
    <#
    .SYNOPSIS
        Genera un informe HTML autónomo (CSS inline, sin JavaScript externo).
    .PARAMETER Entries
        Entradas del inventario.
    .PARAMETER Path
        Ruta del archivo HTML que se va a crear.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ($null -eq $Entries) {
        $Entries = @()
    }

    $computer = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computer)) {
        $computer = [Environment]::MachineName
    }

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $flagged = @($Entries | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-EntryField -Entry $_ -Name 'Marcas')) })
    $byOrigin = @($Entries | Group-Object -Property { [string](Get-EntryField -Entry $_ -Name 'Origen') } | Sort-Object -Property Name)

    $css = @'
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    body {
        margin: 0;
        padding: 32px 24px 48px;
        font-family: "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        font-size: 14px;
        line-height: 1.45;
        color: #1f2328;
        background: #f6f7f9;
    }
    header, main, footer { max-width: 1400px; margin: 0 auto; }
    h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.2px; }
    h2 { font-size: 17px; margin: 32px 0 10px; }
    .meta { margin: 0; color: #59636e; }
    .cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 24px 0 8px; }
    .card {
        flex: 1 1 160px;
        padding: 14px 18px;
        border: 1px solid #d8dee4;
        border-radius: 10px;
        background: #fff;
    }
    .card .num { display: block; font-size: 24px; font-weight: 600; }
    .card .label { color: #59636e; }
    .card-warn { border-color: #e3b341; background: #fff8e5; }
    .card-ok { border-color: #4ac26b; background: #eefbf2; }
    .ok {
        margin: 16px 0 0;
        padding: 12px 16px;
        border: 1px solid #4ac26b;
        border-radius: 8px;
        background: #e6f4ea;
        color: #146c2e;
    }
    .warn {
        margin: 16px 0 0;
        padding: 12px 16px;
        border: 1px solid #e3b341;
        border-radius: 8px;
        background: #fff8e5;
        color: #7a4b00;
    }
    table {
        width: 100%;
        border-collapse: collapse;
        background: #fff;
        border: 1px solid #d8dee4;
        border-radius: 10px;
        overflow: hidden;
    }
    th, td { padding: 8px 10px; text-align: left; vertical-align: top; border-bottom: 1px solid #eaeef2; }
    th { background: #f0f3f6; font-weight: 600; white-space: nowrap; }
    tbody tr:nth-child(even) { background: #fafbfc; }
    tbody tr.flag { background: #fff3cd; }
    tbody tr.flag:nth-child(even) { background: #ffefc2; }
    tbody tr:last-child td { border-bottom: none; }
    .mono { font-family: Consolas, "Cascadia Mono", monospace; font-size: 12px; word-break: break-all; }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
    table.small { max-width: 520px; }
    footer { margin-top: 36px; color: #59636e; font-size: 12px; }
'@

    $rows = New-Object System.Text.StringBuilder
    foreach ($entry in $Entries) {
        $origen = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Origen'))
        $nombre = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Nombre'))
        $comando = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Comando'))
        $ejecutable = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Ejecutable'))
        $firma = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Firma'))
        $firmante = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Firmante'))
        $marcas = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Marcas'))
        $ubicacion = ConvertTo-HtmlText ([string](Get-EntryField -Entry $entry -Name 'Ubicacion'))

        $rowClass = ''
        if (-not [string]::IsNullOrWhiteSpace($marcas)) {
            $rowClass = ' class="flag"'
        }

        $row = '      <tr{0}><td>{1}</td><td>{2}</td><td class="mono">{3}</td><td class="mono">{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td class="mono">{8}</td></tr>' -f $rowClass, $origen, $nombre, $comando, $ejecutable, $firma, $firmante, $marcas, $ubicacion
        [void]$rows.AppendLine($row)
    }

    $originRows = New-Object System.Text.StringBuilder
    foreach ($group in $byOrigin) {
        $groupName = ConvertTo-HtmlText ([string]$group.Name)
        [void]$originRows.AppendLine(('      <tr><td>{0}</td><td class="num">{1}</td></tr>' -f $groupName, $group.Count))
    }

    $verdictClass = 'ok'
    $verdictText = 'No hay entradas marcadas: no se han encontrado indicios de persistencia sospechosa en este equipo.'
    if ($flagged.Count -gt 0) {
        $verdictClass = 'warn'
        $verdictText = ('Hay {0} entrada(s) marcada(s). Investigue cada una antes de deshabilitar o borrar nada.' -f $flagged.Count)
    }

    $cardClass = 'card-ok'
    if ($flagged.Count -gt 0) {
        $cardClass = 'card-warn'
    }

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inventario de arranque autom&aacute;tico - $computer</title>
<style>
$css
</style>
</head>
<body>
<header>
  <h1>Inventario de arranque autom&aacute;tico</h1>
  <p class="meta">Equipo: <strong>$computer</strong> &middot; Generado: $generated &middot; Herramienta de solo lectura</p>
</header>
<main>
  <section class="cards">
    <div class="card"><span class="num">$($Entries.Count)</span><span class="label">Entradas</span></div>
    <div class="card"><span class="num">$($byOrigin.Count)</span><span class="label">Or&iacute;genes</span></div>
    <div class="card $cardClass"><span class="num">$($flagged.Count)</span><span class="label">Marcadas</span></div>
  </section>
  <p class="$verdictClass">$verdictText</p>
  <h2>Recuento por origen</h2>
  <table class="small">
    <thead><tr><th>Origen</th><th class="num">Entradas</th></tr></thead>
    <tbody>
$($originRows.ToString())    </tbody>
  </table>
  <h2>Entradas</h2>
  <table>
    <thead>
      <tr><th>Origen</th><th>Nombre</th><th>Comando</th><th>Ejecutable</th><th>Firma</th><th>Firmante</th><th>Marcas</th><th>Ubicaci&oacute;n</th></tr>
    </thead>
    <tbody>
$($rows.ToString())    </tbody>
  </table>
</main>
<footer>autostart-inventory &middot; no modifica, deshabilita ni borra nada &middot; licencia MIT</footer>
</body>
</html>
"@

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
}

Export-ModuleMember -Function @(
    'Get-ExecutablePath',
    'Get-RunKeyEntries',
    'Get-StartupFolderEntries',
    'Get-TaskEntries',
    'Get-ServiceEntries',
    'Get-WmiPersistenceEntries',
    'Get-SignatureInfo',
    'Get-EntryFlags',
    'ConvertTo-AutostartHtml'
)
