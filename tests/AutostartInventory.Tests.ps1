#Requires -Version 5.1
<#
    Pruebas de Pester (5.5+) del módulo AutostartInventory.
    Se ejecutan con: Invoke-Pester ./tests -Output Detailed
#>

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\lib\AutostartInventory.psm1'
    Import-Module -Name $modulePath -Force
}

Describe 'Get-ExecutablePath' {
    It 'extrae la ruta entre comillas' {
        $result = Get-ExecutablePath -CommandLine '"C:\Program Files\A\b.exe" /min'
        $result | Should -Be 'C:\Program Files\A\b.exe'
    }

    It 'extrae la ruta sin comillas' {
        $result = Get-ExecutablePath -CommandLine 'C:\Tools\x.exe -q'
        $result | Should -Be 'C:\Tools\x.exe'
    }

    It 'expande variables de entorno' {
        $result = Get-ExecutablePath -CommandLine '%windir%\system32\cmd.exe /c y'
        $expected = Join-Path -Path $env:windir -ChildPath 'system32\cmd.exe'
        $result | Should -Be $expected
    }

    It 'devuelve la DLL cuando la orden es rundll32' {
        $result = Get-ExecutablePath -CommandLine 'rundll32.exe C:\L\a.dll,Run'
        $result | Should -Be 'C:\L\a.dll'
    }

    It 'devuelve $null para una cadena vacía' {
        $result = Get-ExecutablePath -CommandLine ''
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Get-EntryFlags' {
    It 'marca un ejecutable sin firma situado en AppData' {
        $entry = [pscustomobject]@{
            Origen     = 'Registro Run'
            Ubicacion  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            Nombre     = 'demo'
            Comando    = 'C:\Users\demo\AppData\Roaming\updater.exe'
            Ejecutable = 'C:\Users\demo\AppData\Roaming\updater.exe'
            Firma      = 'Sin firma'
            Firmante   = ''
            Marcas     = ''
        }

        $flags = Get-EntryFlags -Entry $entry

        $flags | Should -Contain 'Sin firma'
        $flags | Should -Contain 'Ejecutable en carpeta de usuario o Temp'
    }

    It 'no marca un ejecutable firmado en Program Files' {
        $entry = [pscustomobject]@{
            Origen     = 'Servicio'
            Ubicacion  = 'Administrador de servicios'
            Nombre     = 'Demo'
            Comando    = '"C:\Program Files\Demo\demo.exe" -service'
            Ejecutable = 'C:\Program Files\Demo\demo.exe'
            Firma      = 'Firmado'
            Firmante   = 'Demo Corporation'
            Marcas     = ''
        }

        $flags = @(Get-EntryFlags -Entry $entry)
        $flags.Count | Should -Be 0
    }

    It 'marca los lanzadores de scripts' {
        $entry = [pscustomobject]@{
            Origen     = 'Tarea programada'
            Ubicacion  = '\Demo'
            Nombre     = 'Demo'
            Comando    = 'powershell.exe -File C:\Scripts\demo.ps1'
            Ejecutable = 'powershell.exe'
            Firma      = 'Firmado'
            Firmante   = 'Microsoft Corporation'
            Marcas     = ''
        }

        $flags = Get-EntryFlags -Entry $entry
        $flags | Should -Contain 'Lanzador de scripts'
    }

    It 'marca siempre las entradas de WMI' {
        $entry = [pscustomobject]@{
            Origen     = 'WMI'
            Ubicacion  = 'root\subscription'
            Nombre     = 'Demo'
            Comando    = ''
            Ejecutable = $null
            Firma      = ''
            Firmante   = ''
            Marcas     = ''
        }

        $flags = Get-EntryFlags -Entry $entry
        $flags | Should -Contain 'Persistencia WMI'
    }
}

Describe 'Get-SignatureInfo' {
    It 'detecta un ejecutable firmado del sistema' {
        $info = Get-SignatureInfo -Path (Join-Path -Path $env:windir -ChildPath 'System32\notepad.exe')
        $info.Estado | Should -Not -Be 'No existe'
    }

    It 'devuelve No existe para una ruta inexistente' {
        $info = Get-SignatureInfo -Path 'C:\ruta\que\no\existe\demo.exe'
        $info.Estado | Should -Be 'No existe'
    }

    It 'devuelve Sin firma para un script sin firmar' {
        $scriptPath = Join-Path -Path $TestDrive -ChildPath 'sin-firma.ps1'
        Set-Content -LiteralPath $scriptPath -Value 'Write-Output "demo"' -Encoding UTF8

        $info = Get-SignatureInfo -Path $scriptPath
        $info.Estado | Should -Be 'Sin firma'
        $info.Firmante | Should -BeNullOrEmpty
    }

    It 'devuelve No existe cuando no se indica ruta' {
        $info = Get-SignatureInfo -Path ''
        $info.Estado | Should -Be 'No existe'
    }
}

Describe 'Funciones de inventario' {
    It '<_> se ejecuta sin excepción y devuelve filas con el formato esperado' -ForEach @(
        'Get-RunKeyEntries'
        'Get-StartupFolderEntries'
        'Get-TaskEntries'
        'Get-ServiceEntries'
        'Get-WmiPersistenceEntries'
    ) {
        $entries = @(& $_)

        $required = @('Origen', 'Ubicacion', 'Nombre', 'Comando', 'Ejecutable', 'Firma', 'Firmante', 'Marcas')

        foreach ($entry in $entries) {
            if ($null -eq $entry) {
                continue
            }

            $names = $entry.PSObject.Properties.Name
            $missing = @($required | Where-Object { $names -notcontains $_ })
            $missing.Count | Should -Be 0 -Because "a una fila le faltan las propiedades: $($missing -join ', ')"
        }
    }
}

Describe 'ConvertTo-AutostartHtml' {
    It 'crea un informe con el nombre del equipo' {
        $entry = [pscustomobject]@{
            Origen     = 'Registro Run'
            Ubicacion  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            Nombre     = 'demo-updater'
            Comando    = 'C:\Users\demo\AppData\Roaming\updater.exe'
            Ejecutable = 'C:\Users\demo\AppData\Roaming\updater.exe'
            Firma      = 'Sin firma'
            Firmante   = ''
            Marcas     = 'Sin firma; Ejecutable en carpeta de usuario o Temp'
        }

        $path = Join-Path -Path $TestDrive -ChildPath 'report.html'
        ConvertTo-AutostartHtml -Entries @($entry) -Path $path

        Test-Path -LiteralPath $path | Should -BeTrue

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match ([regex]::Escape($env:COMPUTERNAME))
        $content | Should -Match 'demo-updater'
        $content | Should -Match 'flag'
    }

    It 'muestra el mensaje verde cuando no hay entradas marcadas' {
        $entry = [pscustomobject]@{
            Origen     = 'Servicio'
            Ubicacion  = 'Administrador de servicios'
            Nombre     = 'Demo'
            Comando    = '"C:\Program Files\Demo\demo.exe"'
            Ejecutable = 'C:\Program Files\Demo\demo.exe'
            Firma      = 'Firmado'
            Firmante   = 'Demo Corporation'
            Marcas     = ''
        }

        $path = Join-Path -Path $TestDrive -ChildPath 'report-limpio.html'
        ConvertTo-AutostartHtml -Entries @($entry) -Path $path

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'No hay entradas marcadas'
        $content | Should -Match 'class="ok"'
    }

    It 'genera un informe válido aunque no haya entradas' {
        $path = Join-Path -Path $TestDrive -ChildPath 'report-vacio.html'
        ConvertTo-AutostartHtml -Entries @() -Path $path

        Test-Path -LiteralPath $path | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'No hay entradas marcadas'
    }
}
