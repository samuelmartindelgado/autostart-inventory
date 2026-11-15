# autostart-inventory

[![CI](https://github.com/samuelmartindelgado/autostart-inventory/actions/workflows/ci.yml/badge.svg)](https://github.com/samuelmartindelgado/autostart-inventory/actions/workflows/ci.yml)

Inventario **de solo lectura** de todo lo que arranca solo en un equipo Windows, con la firma
digital de cada ejecutable. En una sola pasada un técnico ve qué se ejecuta al encender o al
iniciar sesión, qué está firmado y qué resulta raro.

## Para qué sirve

- Ver de un vistazo **qué programas se inician solos** en el equipo.
- Detectar **programas no deseados, adware o malware persistente** que se esconden en claves
  `Run`, tareas programadas, servicios o suscripciones WMI.
- Comprobar la **firma digital** de cada ejecutable y localizar binarios sin firmar, con firma
  rota o guardados en carpetas donde cualquier usuario puede escribir.
- Guardar una **instantánea** (`JSON`, `CSV`, `HTML`) para comparar equipos o revisar un caso.

> La herramienta **no modifica, no deshabilita y no borra nada**. Solo lee.

## Qué revisa

| Origen | Dónde mira |
| --- | --- |
| `Registro Run` | `HKLM` y `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` y `RunOnce`, más `HKLM\Software\WOW6432Node\...\Run` |
| `Carpeta Inicio` | Carpeta Inicio común (`CommonStartup`) y del usuario (`Startup`); resuelve los `.lnk` |
| `Tarea programada` | Tareas con disparador de arranque (`MSFT_TaskBootTrigger`) o de inicio de sesión (`MSFT_TaskLogonTrigger`) y acción `Exec`. Las de `\Microsoft\` se omiten salvo con `-IncludeMicrosoft` |
| `Servicio` | Servicios `Win32_Service` con `StartMode = Auto` |
| `WMI` | Consumidores de eventos en `root\subscription`: `CommandLineEventConsumer` y `ActiveScriptEventConsumer` |

Cada fila tiene las columnas `Origen`, `Ubicacion`, `Nombre`, `Comando`, `Ejecutable`, `Firma`,
`Firmante` y `Marcas`.

## Requisitos

- Windows 10/11 o Windows Server.
- **Windows PowerShell 5.1** o **PowerShell 7+**.
- Sin módulos externos y **sin permisos de administrador**: lo que no se pueda leer se omite y se
  avisa en el resumen.

## Uso

```powershell
# Inventario completo en .\salida (autostart.json, autostart.csv y report.html)
.\Get-AutostartInventory.ps1 -OutputPath .\salida

# Solo las entradas marcadas
.\Get-AutostartInventory.ps1 -OnlySuspicious -OutputPath .\salida

# Incluir también lo firmado por Microsoft y la carpeta \Microsoft\ de tareas
.\Get-AutostartInventory.ps1 -IncludeMicrosoft -OutputPath .\salida
```

Parámetros:

| Parámetro | Tipo | Descripción |
| --- | --- | --- |
| `-OutputPath` | `string` | Carpeta de salida (por defecto el directorio actual). Crea `autostart.json`, `autostart.csv` y `report.html` |
| `-OnlySuspicious` | `switch` | Muestra y escribe solo las filas con alguna marca |
| `-IncludeMicrosoft` | `switch` | Incluye entradas firmadas por Microsoft y tareas de `\Microsoft\` (por defecto se ocultan) |

Código de salida: **0** si no hay entradas marcadas, **1** si hay alguna. Así se puede usar en
un script de revisión o en CI.

Las entradas firmadas por Microsoft se ocultan por defecto para no llenar la tabla de ruido. Si
alguna de las ocultas tuviera marcas, el resumen lo avisa; en ese caso conviene repetir la
ejecución con `-IncludeMicrosoft`.

## Ejemplo de salida (datos ficticios)

```text
Inventario de arranque automático · PC-DEMO · 2026-01-15 09:30
Entradas: 42 | Mostradas: 18 | Marcadas: 3
Ocultas por firma de Microsoft: 24 (use -IncludeMicrosoft para verlas)

Origen             Nombre              Firma      Marcas
------             ------              -----      ------
Registro Run       demo-updater        Sin firma  Sin firma; Ejecutable en carpeta de usuario o Temp
Tarea programada   DemoBackup          Firmado
Servicio           DemoAgent           Firmado    Lanzador de scripts
WMI                DemoWmiConsumer     No existe  El ejecutable no existe; Persistencia WMI
```

En `report.html` las filas marcadas aparecen en **ámbar** y, si no hay ninguna, se muestra un
mensaje verde de "sin entradas marcadas". El informe es autónomo: CSS incluido, sin JavaScript
externo y sin conexiones de red.

## Qué significa cada marca y qué hacer

| Marca | Significado | Qué hacer |
| --- | --- | --- |
| `Sin firma` | El archivo no tiene firma Authenticode (habitual en software casero, pero también en malware) | Comprobar de qué programa es y si lo instaló alguien del equipo |
| `Firma no válida` | La firma existe pero no es válida (manipulada, caducada o rota) | Tratar como sospechoso: no ejecutar y analizar con el antivirus |
| `El ejecutable no existe` | La entrada apunta a una ruta que ya no existe (resto de una desinstalación o de un ataque) | Revisar si es basura; si no se reconoce, investigar el origen |
| `Ejecutable en carpeta de usuario o Temp` | El binario vive en el perfil del usuario, `AppData`, `Temp` o `C:\Users\Public`, donde no hace falta ser administrador para escribir | Muy sospechoso en un arranque automático: verificar el archivo y su origen |
| `Lanzador de scripts` | El arranque usa `powershell`, `cmd`, `wscript`, `cscript`, `mshta`, `rundll32` o `regsvr32` | Leer la línea de comandos completa y el script al que apunta antes de nada |
| `Persistencia WMI` | Hay un consumidor de eventos en `root\subscription`; cualquier entrada aquí se marca siempre | Técnica clásica de persistencia: investigar y, si es desconocida, tratarla con ayuda experta |

**Antes de borrar nada, investigue**: compruebe la ruta, el firmante, la fecha del archivo y si
el programa corresponde a algo instalado a propósito. Para desactivar algo legítimo, use el
**Administrador de tareas** (pestaña Inicio), `services.msc` para servicios o el **Programador de
tareas** para tareas. La herramienta no cambia nada por usted.

## Estructura del repositorio

```text
Get-AutostartInventory.ps1        Script principal (parámetros, filtros, salida y resumen)
lib/AutostartInventory.psm1       Módulo con la lógica de recogida, firmas, marcas y HTML
tests/AutostartInventory.Tests.ps1 Pruebas Pester 5+
.github/workflows/ci.yml          CI en windows-latest (análisis + tests + ejecución real)
PSScriptAnalyzerSettings.psd1     Configuración del análisis estático
```

## Pruebas

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Las pruebas usan `$TestDrive` y no tocan el sistema: solo leen. En CI se ejecuta además el
inventario real con PowerShell 7 y con Windows PowerShell 5.1.

## Licencia

MIT. Consulte [LICENSE](LICENSE).

---

## English summary

`autostart-inventory` is a **read-only** PowerShell tool for Windows that lists everything that
starts automatically: `Run`/`RunOnce` registry keys, Startup folders, scheduled tasks with boot or
logon triggers, automatic services and WMI event consumers. Each entry includes the executable's
digital signature status and risk flags (unsigned, invalid signature, missing file, user-writable
path, script launcher, WMI persistence).

It works on Windows PowerShell 5.1 and PowerShell 7, needs no external modules and no admin
rights (unreadable sources are skipped and reported). It writes `autostart.json`,
`autostart.csv` and a self-contained `report.html`, and exits with `0` when nothing is flagged or
`1` when at least one entry is flagged. It never modifies, disables or deletes anything.
Licensed under MIT.
