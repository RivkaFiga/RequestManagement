<#
.SYNOPSIS
    T-501 shared helpers for run-sql.ps1 and measure-api.ps1. Dot-sourced; it defines functions and constants only and
    starts nothing by itself.

.DESCRIPTION
    Holds the one definition of the things both scripts (and test-perf-scripts.ps1) must agree on:
      - the scenarios and their statements (work plan section 5.1),
      - the output file names (section 5.3 and docs/perf/DEVIATIONS.md, deviation A), which T-502 reuses for 'after',
      - the SQL the scripts may send, and how it is restricted (see "SQL policy" below),
      - the safety guard calls and the approval that every connection and every API start must hold,
      - the child-process wrapper (full tool paths), the result parsers and the transactional publishing of results.

    SQL policy (the trust boundary is this file; docs/perf/sql is data):
      1. Invoke-PerfSqlcmd has no parameter for SQL text. A caller names a KIND (StatsRun, Fidelity, DatasetCheck, IndexListing,
         ServerVersion) and, for the first two, the id of a captured statement (for example 'B1a.count').
      2. A captured statement exists only after Register-PerfStatements accepted it: its SHA-256 must equal the value in
         $script:PerfApprovedHashes below. A changed docs/perf/sql file is refused (SQL_NOT_APPROVED) until someone reviews
         the new text and updates the hash here.
      3. Every text that reaches sqlcmd, approved or built by this file, is checked once more by Assert-ReadOnlySql, a
         deny-by-default grammar: only SET STATISTICS IO|TIME|XML ON, SET NOCOUNT ON, SELECT, and EXEC sp_executesql with a
         literal SELECT; no sqlcmd commands, comments, INTO, USE, NEXT VALUE FOR, other SET options or other statements.
      Step 2 is exact. Step 3 is a second line of defence for the templates in this file; it is tested offline, it has not
      been run against SQL Server's own parser, and it is not presented as a proof.

    Every process the scripts start goes through Invoke-ChildProcess, which only starts the tools of $script:PerfAllowedTools,
    by the full path that Resolve-PerfTool found. When T501_CHILD_LOG names a file, each launch is appended to it first; the
    offline tests use that to prove that a dry run starts nothing.
#>

$script:PerfEnvName = 'ConnectionStrings__RequestManagement'
$script:PerfDatabase = 'RequestManagement_Perf'
$script:PerfContainer = 'request-management-sql'
$script:PerfDir = $PSScriptRoot
$script:PerfRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:PerfSqlDir = Join-Path $PSScriptRoot 'sql'
$script:PerfDefaultResults = Join-Path $PSScriptRoot 'results'
$script:PerfGuardPath = Join-Path $PSScriptRoot 'guard-perf-target.ps1'
$script:PerfKeepDir = $null
$script:PerfKeepOnFailure = $false
$script:PerfCleanup = $null
$script:PerfGuardApproval = $null
$script:PerfStatements = @{}
$script:PerfResolvedTools = @{}
if (-not (Get-Variable -Name PerfTool -Scope Script -ErrorAction SilentlyContinue)) { $script:PerfTool = 'PERF' }

# Work plan section 5.2, steps 3 and 4.
$script:SqlWarmupRuns = 1
$script:SqlMeasuredRuns = 5
$script:ApiWarmupCalls = 10
$script:ApiMeasuredCalls = 100

# The query-shaping sources the captured SQL depends on (the header of every docs/perf/sql file names the same three).
$script:PerfQuerySourcePaths = @(
    'backend/src/RequestManagement.Core',
    'backend/src/RequestManagement.Infrastructure/Requests',
    'backend/src/RequestManagement.Infrastructure/Persistence'
)

# The five indexes of the AddQueryIndexes migration. 'before' must have none of them, 'after' all of them.
$script:PerfIndexNames = @(
    'IX_Requests_CreatedAt_Id',
    'IX_Requests_Status_CreatedAt',
    'IX_Requests_AssignedTo_Status_CreatedAt',
    'IX_Requests_OrganizationName_CreatedAt',
    'IX_Requests_Priority_Status'
)

# Work plan section 5.1. Parts are the statements of a scenario, in execution order, as named in docs/perf/sql/<Id>.sql.
$script:PerfScenarios = @(
    [pscustomobject]@{ Id = 'B1a'; Parts = @('count', 'data') },
    [pscustomobject]@{ Id = 'B1b'; Parts = @('count', 'data') },
    [pscustomobject]@{ Id = 'B1c'; Parts = @('count', 'data') },
    [pscustomobject]@{ Id = 'B1d'; Parts = @('count', 'data') },
    [pscustomobject]@{ Id = 'B1e'; Parts = @('count', 'data') },
    [pscustomobject]@{ Id = 'B1f'; Parts = @('count', 'data') },
    [pscustomobject]@{ Id = 'B2'; Parts = @('status', 'priority') }
)

# SHA-256 (UTF-8, line breaks as LF, trimmed) of every captured statement and of every '-- request:' line that the scripts
# may use. Computed from docs/perf/sql at captured commit bfc3a18 (B1e and B1f: 9db54a1, query-shaping sources identical). Re-capturing the SQL changes these on purpose: review the
# new text, then update the values here. (B1b.count and B1d.count are the same statement.)
$script:PerfApprovedHashes = @{
    'B1a.count'    = '652456D7FC94CB0DDC6DA861EC5433C87D138A84FDDE48411417159010E90B38'
    'B1a.data'     = '58241E8CA08F58988A67C92675D32EB10DB8918D7D4C72A9AC7FFB55B23F563A'
    'B1a.request'  = 'BF21C668197A3DEC71E05EC12666B57C6FAD9FE9170C80D5CB0C13D4D1EEE63F'
    'B1b.count'    = '7493BFC8249322C3A099F9486970241CE25A9449AA49AE4FFBA6B2BAA8907B17'
    'B1b.data'     = '9CFC8B8BB4314A3CB7E2552F4AA772B7FE0F8DC54FF0B64C17EEF166E1321F42'
    'B1b.request'  = '2160E5AB380CE270C0DD631D18C71EDCF475BE9ECD2E304ACCBC9E462AE8447B'
    'B1c.count'    = '8FCC9FC16CB55F6BF629AEE70492C08A43093CBCF39E553250A4B3CB64BB5F99'
    'B1c.data'     = '498E936945D07E92CAA5C5F188B4605DFE5059C6A1F42540CCD70F5C40778AD4'
    'B1c.request'  = '720696693CA7EDF387A158FDC76F45955AD1025A6D2DFF19D11EF3725C6CBFD3'
    'B1d.count'    = '7493BFC8249322C3A099F9486970241CE25A9449AA49AE4FFBA6B2BAA8907B17'
    'B1d.data'     = '288CAA4DDA325F308A35D9E3CB5D5C58E4011B82C406B63893FBEDC97BB3254B'
    'B1d.request'  = '5976F682DEB13E2CDE645FA5247D70D6CC7512AA6FAC4D7196EE88E400397817'
    'B1e.count'    = '919BE75537C448A5C29F8A0EB2DFA1C441B91AA86C4AE05611F193395F84A391'
    'B1e.data'     = 'D6C23261833B52A9534A4B83D9232398BEC27568E4E1984369D39C36DAC5D5E6'
    'B1e.request'  = 'E6D0C0D48F70A8EFEF41B8DBCA029656FCD014509AE765BF6CC8FF5C5EA06D26'
    'B1f.count'    = '12E430EFBC2AEE048B75D0972F5A1436D5D1E09741B1306CA3B19A57A8DA7F9E'
    'B1f.data'     = 'EBAE5ED250DA49BE35AF142516A9BA947F2EC849E137FCE00F4B7EF47C80F733'
    'B1f.request'  = '1F0F14F76CD8AADB7563B36C881296FACB5CA0EDB9EDE3D7E8888DD8ED6FD980'
    'B2.status'    = '8C08083732A4511B0B5466958432E7029B8D12A1C5EB8B78FC14D7CD9DEC2A78'
    'B2.priority'  = '794BA0863B2E917BD0DEC20B8A7DAD2FBB3C1F5C8CBE928C06C9F12727616374'
    'B2.request'   = 'B2EFEB3DB0D8CDEBDAB555453F46F8216C4E6C3734500C7446A2436183B4EBE6'
}

# The only programs the scripts start. 'sqlcmd' and 'dotnet' additionally need the guard's approval (Invoke-ChildProcess).
$script:PerfAllowedTools = @('sqlcmd', 'git', 'docker', 'dotnet', 'powershell.exe')
$script:PerfGuardedTools = @('sqlcmd', 'dotnet')

# The guard only defines functions when dot-sourced. Its parameters ($CheckServer, $Container) become variables here,
# so the scripts that load this file must not declare parameters with those names.
. $script:PerfGuardPath

# ---- stopping, cleanup, output and processes -----------------------------------------------------------------------

# Removes the run's temporary folder (SQL batches, staged results, API logs, isolated APPDATA). Refuses anything that is not
# a t501-perf-* folder directly in the temp folder, and anything that contains a link (junction or symlink), so a removal can
# never follow a link out of the folder.
function Remove-PerfWorkDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) { $script:PerfKeepDir = $null; return $true }
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Dir)
    if (-not ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and ((Split-Path $full -Leaf) -like 't501-perf-*') -and ((Split-Path $full -Parent).TrimEnd('\') -ieq $temp.TrimEnd('\')))) {
        return $false
    }
    $links = @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count -gt 0) { return $false }
    try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop } catch { return $false }
    $script:PerfKeepDir = $null
    $true
}

# Stops a running API (when the script registered one) and removes the temporary folder, unless -KeepWorkOnFailure was given.
function Invoke-PerfFailureCleanup {
    if ($script:PerfCleanup) { try { & $script:PerfCleanup } catch { } }
    if ($script:PerfKeepDir) {
        if ($script:PerfKeepOnFailure) {
            Write-Host "$($script:PerfTool): the temporary folder '$($script:PerfKeepDir)' was kept (-KeepWorkOnFailure). It holds SQL batches and API logs; delete it when done."
        }
        elseif (Remove-PerfWorkDir $script:PerfKeepDir) {
            Write-Host "$($script:PerfTool): the temporary folder was removed. Nothing was moved into the results folder."
        }
        else {
            Write-Host "$($script:PerfTool): the temporary folder '$($script:PerfKeepDir)' could not be removed safely; delete it by hand. Nothing was moved into the results folder."
        }
    }
}

function Stop-Run([string]$Code, [string]$Message) {
    Write-Host "$($script:PerfTool): STOP [$Code] $Message" -ForegroundColor Red
    Invoke-PerfFailureCleanup
    exit 1
}

function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
}

function Hide-Secrets([string]$Text, [string]$Password) {
    $lines = $Text -split "`r?`n" | Where-Object { $_ -notmatch '(?i)password|pwd=' }
    $joined = $lines -join "`n"
    if ($Password) { $joined = $joined.Replace($Password, '***') }
    $joined
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---- external tools: full paths only ---------------------------------------------------------------------------------

# A tool found through PATH must be an absolute path, outside the current folder and outside the repository, so that a
# program planted in the folder a script is started from (or in the repository) is never run.
function Test-PerfToolPathAllowed([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    $dir = [IO.Path]::GetDirectoryName($full).TrimEnd('\')
    if ($dir -ieq (Get-Location).ProviderPath.TrimEnd('\')) { return $false }
    if ($full.StartsWith($script:PerfRepo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $true
}

function Resolve-PerfTool([string]$Name) {
    $key = $Name.ToLowerInvariant()
    if ($script:PerfAllowedTools -notcontains $key) { Stop-Run 'TOOL_NOT_ALLOWED' "'$Name' is not one of the tools these scripts may start ($($script:PerfAllowedTools -join ', '))." }
    if ($script:PerfResolvedTools.ContainsKey($key)) { return $script:PerfResolvedTools[$key] }
    if ($key -eq 'powershell.exe') { $path = Join-Path $PSHOME 'powershell.exe' }
    else {
        $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { Stop-Run 'TOOL_MISSING' "$Name was not found on PATH." }
        $path = $command.Source
    }
    if (-not (Test-PerfToolPathAllowed $path)) {
        Stop-Run 'TOOL_NOT_ALLOWED' "$Name resolves to '$path', which is not an absolute path outside the current folder and the repository."
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Run 'TOOL_MISSING' "$Name resolves to '$path', which does not exist." }
    $script:PerfResolvedTools[$key] = $path
    $path
}

# ---- the guard's approval ----------------------------------------------------------------------------------------------

function Get-PerfConnectionHash {
    Get-Sha256Hex ([string][Environment]::GetEnvironmentVariable($script:PerfEnvName, 'Process'))
}

# Fails unless Invoke-ServerGuard succeeded in this process for exactly the connection string that is in the environment now
# (and, when a builder is given, for exactly that server and database). Called inside every function that connects.
function Assert-GuardApproved($Builder = $null) {
    $approval = $script:PerfGuardApproval
    if ($null -eq $approval) { Stop-Run 'GUARD_NOT_APPROVED' 'The server guard has not approved the target in this process; nothing was connected or started.' }
    if ($approval.Database -cne $script:PerfDatabase) { Stop-Run 'GUARD_NOT_APPROVED' 'The guard approval is not for the performance database.' }
    if ($approval.ConnectionHash -cne (Get-PerfConnectionHash)) { Stop-Run 'GUARD_NOT_APPROVED' 'The connection string changed after the guard approved it; nothing was connected or started.' }
    if ($null -ne $Builder -and ($Builder.DataSource -cne $approval.Server -or $Builder.InitialCatalog -cne $approval.Database)) {
        Stop-Run 'GUARD_NOT_APPROVED' 'The target of this call is not the target the guard approved.'
    }
}

# The guard with -CheckServer, as a separate process, before the first connection of a run. Only a clean exit AND the guard's
# own "GUARD: OK" line for exactly this server and database create the approval.
function Invoke-ServerGuard($Builder) {
    $script:PerfGuardApproval = $null
    $run = Invoke-ChildProcess -FileName 'powershell.exe' -TimeoutSeconds 120 `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:PerfGuardPath, '-CheckServer', '-Container', $script:PerfContainer)
    Write-Host ((Hide-Secrets ($run.Stdout + $run.Stderr) $Builder.Password).Trim())
    if ($run.ExitCode -ne 0) { Stop-Run 'GUARD_FAILED' "guard-perf-target.ps1 -CheckServer exited with $($run.ExitCode)." }
    $ok = [regex]::Match($run.Stdout, "(?m)^GUARD: OK - server '([^']+)', database '([^']+)'")
    if (-not $ok.Success -or $ok.Groups[1].Value -cne $Builder.DataSource -or $ok.Groups[2].Value -cne $script:PerfDatabase) {
        Stop-Run 'GUARD_FAILED' "The guard exited with 0 but did not confirm server '$($Builder.DataSource)' and database '$($script:PerfDatabase)'."
    }
    $script:PerfGuardApproval = [pscustomobject]@{
        Server = $Builder.DataSource
        Database = $script:PerfDatabase
        ConnectionHash = (Get-PerfConnectionHash)
    }
}

# Ends a process and all its descendants, children first. A killed database connection is rolled back by SQL Server.
function Stop-PerfProcessTree([int]$ProcessId) {
    foreach ($child in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)) {
        Stop-PerfProcessTree ([int]$child.ProcessId)
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
}

# Starts a child with an explicit environment. $ChildEnv entries override the inherited ones; a $null value removes the variable.
# The program is one of $script:PerfAllowedTools, started by its full path; sqlcmd and dotnet need the guard's approval.
function Invoke-ChildProcess {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [hashtable]$ChildEnv = @{},
        [string]$WorkingDirectory = $script:PerfRepo,
        [int]$TimeoutSeconds = 600
    )
    # The approval is checked first, by the name of the tool, before anything is looked up or started.
    $leaf = [IO.Path]::GetFileNameWithoutExtension($FileName).ToLowerInvariant()
    if ($script:PerfGuardedTools -contains $leaf) { Assert-GuardApproved }
    if ([IO.Path]::IsPathRooted($FileName)) {
        if (@($script:PerfResolvedTools.Values) -notcontains $FileName) { Stop-Run 'TOOL_NOT_ALLOWED' "'$FileName' was not resolved by Resolve-PerfTool." }
        $path = $FileName
    }
    else { $path = Resolve-PerfTool $FileName }
    if ($env:T501_CHILD_LOG) {
        Add-Content -LiteralPath $env:T501_CHILD_LOG -Value ("{0} {1}" -f $path, ($Arguments -join ' '))
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $path
    $psi.Arguments = (($Arguments | ForEach-Object {
        if ($_ -eq '') { '""' } elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($key in $ChildEnv.Keys) {
        if ($null -eq $ChildEnv[$key]) { [void]$psi.EnvironmentVariables.Remove($key) }
        else { $psi.EnvironmentVariables[$key] = [string]$ChildEnv[$key] }
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        # Process.Kill() ends only the process itself; a tool such as `dotnet ef` runs its work in a child that would go on.
        Stop-PerfProcessTree $process.Id
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Stdout = ''; Stderr = "timed out after $TimeoutSeconds s" }
    }
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result }
}

function New-PerfWorkDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('t501-perf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:PerfKeepDir = $dir
    $dir
}

# ---- paths ---------------------------------------------------------------------------------------------------------------

# The canonical spelling of a path: long names (8.3 aliases expanded), the real case of every existing component, and whether
# any existing component is a reparse point (junction or symlink). Components that do not exist yet are kept as written.
function Get-PerfCanonicalPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $parts = @($full.Substring($root.Length) -split '\\' | Where-Object { $_ -ne '' })
    $output = $root.TrimEnd('\')
    $current = $root
    $exists = $true
    $reparse = $false
    foreach ($part in $parts) {
        if ($exists) {
            $entry = $null
            try { $entry = @((New-Object System.IO.DirectoryInfo($current)).GetFileSystemInfos($part)) | Select-Object -First 1 }
            catch { Stop-Run 'RESULTS_ROOT_INVALID' "The path '$Path' cannot be inspected ($($_.Exception.Message))." }
            if ($null -ne $entry) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $reparse = $true }
                $output = $output + '\' + $entry.Name
                $current = $entry.FullName
            }
            else { $exists = $false; $output = $output + '\' + $part }
        }
        else { $output = $output + '\' + $part }
    }
    [pscustomobject]@{ Path = $output; HasReparsePoint = $reparse }
}

# The results root: absolute, local, no wildcard or stream syntax, no link anywhere on its existing path, and not inside the
# official docs/perf/results folder. The official folder itself is returned as that folder's own path.
function Resolve-PerfResultsRoot([string]$ResultsRoot) {
    if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { return $script:PerfDefaultResults }
    if ($ResultsRoot -match '[*?"<>|]' -or $ResultsRoot.StartsWith('\\') -or $ResultsRoot.StartsWith('//')) {
        Stop-Run 'RESULTS_ROOT_INVALID' 'The results root has wildcard characters or is a UNC/device path.'
    }
    if (-not [IO.Path]::IsPathRooted($ResultsRoot)) { $ResultsRoot = Join-Path (Get-Location).ProviderPath $ResultsRoot }
    try { $full = [IO.Path]::GetFullPath($ResultsRoot) }
    catch { Stop-Run 'RESULTS_ROOT_INVALID' 'The results root is not a valid path.' }
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { Stop-Run 'RESULTS_ROOT_INVALID' 'The results root must be a plain local path on a drive.' }
    $canonical = Get-PerfCanonicalPath $full
    $official = (Get-PerfCanonicalPath $script:PerfDefaultResults).Path
    if ($canonical.Path -ieq $official) { return $script:PerfDefaultResults }
    if ($canonical.HasReparsePoint) {
        Stop-Run 'RESULTS_ROOT_REPARSE' 'A folder on the path of the results root is a junction or symbolic link; it could lead into the official results. Use a real folder.'
    }
    if ($canonical.Path.StartsWith($official + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Run 'RESULTS_ROOT_INSIDE_OFFICIAL' 'The results root is inside docs/perf/results.'
    }
    $canonical.Path
}

function Test-PerfDefaultResults([string]$ResolvedRoot) {
    (Get-PerfCanonicalPath $ResolvedRoot).Path -ieq (Get-PerfCanonicalPath $script:PerfDefaultResults).Path
}

# ---- scenarios and output names ----------------------------------------------------------------------------------------

# Keeps the order of section 5.1; an empty selection means all scenarios.
function Get-SelectedScenarios([string[]]$Names) {
    if (-not $Names -or $Names.Count -eq 0) { return @($script:PerfScenarios) }
    @($script:PerfScenarios | Where-Object { $Names -contains $_.Id })
}

# Names written by run-sql.ps1, relative to the results root. Deviation A: one .sqlplan per statement (<scenario>.<part>.sqlplan);
# .stats.txt stays one file per scenario. T-502 must produce the same names under 'after/'.
function Get-SqlOutputFiles([string]$Phase, $Scenarios) {
    $files = New-Object System.Collections.Generic.List[string]
    $files.Add("$Phase/indexes.txt")
    $files.Add("$Phase/dataset-check.txt")
    foreach ($scenario in $Scenarios) {
        $files.Add("$Phase/$($scenario.Id).stats.txt")
        foreach ($part in $scenario.Parts) { $files.Add("$Phase/$($scenario.Id).$part.sqlplan") }
    }
    $files.Add("$Phase/fidelity.txt")
    $files.ToArray()
}

# Names written by measure-api.ps1. api.csv holds the p50/p95 required by section 5.3 (deviation C was not adopted);
# api-calls.csv holds the individual timings.
function Get-ApiOutputFiles([string]$Phase) {
    "$Phase/api.csv"
    "$Phase/api-calls.csv"
    "$Phase/api-run.txt"
}

# Written once, at the root of the results folder, by run-sql.ps1 in phase 'before' (section 5.2, step 6). Never overwritten.
$script:PerfEnvironmentFile = 'environment.txt'

function Get-ExistingOutputFiles([string]$ResultsRoot, [string[]]$Relative) {
    $Relative | Where-Object { Test-Path -LiteralPath (Join-Path $ResultsRoot ($_ -replace '/', '\')) }
}

# Publishes a finished staging folder as one transaction. Each file is first copied next to its target as <name>.t501-new;
# only when every copy is verified is each existing target renamed to <name>.t501-old and the copy renamed into place. If
# anything fails, every step is undone in reverse order (targets restored, copies removed, folders this call created removed),
# so the results folder holds either all of the old files or all of the new ones. $CreateOnly files may not exist at all.
function Publish-PerfOutput([string]$StagingDir, [string]$ResultsRoot, [string[]]$Relative, [bool]$Overwrite, [string[]]$CreateOnly = @()) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(@($Relative | ForEach-Object { @{ Rel = $_; Replace = $Overwrite } }) + @($CreateOnly | ForEach-Object { @{ Rel = $_; Replace = $false } }))) {
        $target = Join-Path $ResultsRoot ($entry.Rel -replace '/', '\')
        $items.Add([pscustomobject]@{
            Rel = $entry.Rel; Replace = $entry.Replace
            Staged = (Join-Path $StagingDir ($entry.Rel -replace '/', '\'))
            Target = $target; New = ($target + '.t501-new'); Old = ($target + '.t501-old')
            OldMade = $false; Placed = $false
        })
    }
    foreach ($item in $items) {
        if (-not (Test-Path -LiteralPath $item.Staged -PathType Leaf)) { Stop-Run 'OUTPUT_INCOMPLETE' "The run did not produce '$($item.Rel)'." }
        if ((Test-Path -LiteralPath $item.Target) -and (-not $item.Replace -or (Test-Path -LiteralPath $item.Target -PathType Container))) {
            Stop-Run 'RESULTS_EXIST' "'$($item.Rel)' exists and was not replaced."
        }
        foreach ($leftover in @($item.New, $item.Old)) {
            if (Test-Path -LiteralPath $leftover) { Stop-Run 'PUBLISH_LEFTOVER' "'$leftover' is left over from an interrupted publish; check it and delete it before running again." }
        }
    }

    $createdDirs = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($item in $items) {
            $missing = New-Object System.Collections.Generic.List[string]
            $dir = Split-Path $item.Target -Parent
            while ($dir -and -not (Test-Path -LiteralPath $dir)) { $missing.Add($dir); $dir = Split-Path $dir -Parent }
            for ($i = $missing.Count - 1; $i -ge 0; $i--) {
                New-Item -ItemType Directory -Path $missing[$i] -ErrorAction Stop | Out-Null
                $createdDirs.Add($missing[$i])
            }
            Copy-Item -LiteralPath $item.Staged -Destination $item.New -ErrorAction Stop
            if ((Get-Item -LiteralPath $item.New -ErrorAction Stop).Length -ne (Get-Item -LiteralPath $item.Staged -ErrorAction Stop).Length) {
                throw "The copy of '$($item.Rel)' differs in size from the staged file."
            }
        }
        foreach ($item in $items) {
            if (Test-Path -LiteralPath $item.Target) {
                Move-Item -LiteralPath $item.Target -Destination $item.Old -ErrorAction Stop
                $item.OldMade = $true
            }
            Move-Item -LiteralPath $item.New -Destination $item.Target -ErrorAction Stop
            $item.Placed = $true
        }
    }
    catch {
        $reason = $_.Exception.Message
        $problems = New-Object System.Collections.Generic.List[string]
        for ($i = $items.Count - 1; $i -ge 0; $i--) {
            $item = $items[$i]
            try {
                if ($item.Placed) { Remove-Item -LiteralPath $item.Target -Force -ErrorAction Stop; $item.Placed = $false }
                if ($item.OldMade) { Move-Item -LiteralPath $item.Old -Destination $item.Target -ErrorAction Stop; $item.OldMade = $false }
                if (Test-Path -LiteralPath $item.New) { Remove-Item -LiteralPath $item.New -Force -ErrorAction Stop }
            }
            catch { $problems.Add("$($item.Rel): $($_.Exception.Message)") }
        }
        for ($i = $createdDirs.Count - 1; $i -ge 0; $i--) {
            try { if (@(Get-ChildItem -LiteralPath $createdDirs[$i] -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $createdDirs[$i] -ErrorAction Stop } }
            catch { $problems.Add("folder $($createdDirs[$i]): $($_.Exception.Message)") }
        }
        if ($problems.Count -gt 0) {
            Stop-Run 'PUBLISH_ROLLBACK_FAILED' "Publishing failed ($reason) and the rollback was incomplete: $($problems -join ' | '). Inspect the results folder for *.t501-old and *.t501-new files before doing anything else."
        }
        Stop-Run 'PUBLISH_FAILED' "Publishing failed ($reason). Every step was rolled back; the results folder is as it was."
    }
    $notRemoved = @()
    foreach ($item in $items) {
        if ($item.OldMade) {
            try { Remove-Item -LiteralPath $item.Old -Force -ErrorAction Stop } catch { $notRemoved += $item.Old }
        }
    }
    if ($notRemoved.Count -gt 0) { Write-Host "$($script:PerfTool): the new results are in place; these backups could not be deleted: $($notRemoved -join ', ')" }
}

# ---- the captured SQL -----------------------------------------------------------------------------------------------

# Reads docs/perf/sql/<Id>.sql: the '-- request:' and '-- captured from commit:' headers and the parts between '-- part:' and GO.
function Read-PerfSqlFile([string]$Id, [string[]]$ExpectedParts) {
    $path = Join-Path $script:PerfSqlDir "$Id.sql"
    if (-not (Test-Path -LiteralPath $path)) { Stop-Run 'SQL_FILE_MISSING' "docs/perf/sql/$Id.sql does not exist." }
    $text = [IO.File]::ReadAllText($path)
    $request = $null
    $commit = $null
    $parts = New-Object System.Collections.Generic.List[object]
    $currentName = $null
    $current = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^-- request: (.*)$') { $request = $matches[1].Trim(); continue }
        if ($line -match '^-- captured from commit: ([0-9a-f]{7,40});') { $commit = $matches[1]; continue }
        if ($line -match '^-- part: (\S+)\s*$') { $currentName = $matches[1]; $current.Clear(); continue }
        if ($line -ceq 'GO') {
            if ($currentName) { $parts.Add([pscustomobject]@{ Name = $currentName; Sql = (($current -join "`n").Trim()) }) }
            $currentName = $null
            $current.Clear()
            continue
        }
        if ($currentName) { $current.Add($line) }
    }
    $names = @($parts | ForEach-Object { $_.Name })
    if (($names -join ',') -cne ($ExpectedParts -join ',')) {
        Stop-Run 'SQL_FILE_INVALID' "docs/perf/sql/$Id.sql has the parts '$($names -join ',')', expected '$($ExpectedParts -join ',')'."
    }
    if (-not $request) { Stop-Run 'SQL_FILE_INVALID' "docs/perf/sql/$Id.sql has no '-- request:' header." }
    if (-not $commit) { Stop-Run 'SQL_FILE_INVALID' "docs/perf/sql/$Id.sql has no '-- captured from commit:' header." }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part.Sql)) { Stop-Run 'SQL_FILE_INVALID' "docs/perf/sql/$Id.sql part '$($part.Name)' is empty." }
        if ([regex]::IsMatch($part.Sql, '[^\x00-\x7F]')) { Stop-Run 'SQL_FILE_INVALID' "docs/perf/sql/$Id.sql part '$($part.Name)' has non-ASCII characters." }
    }
    [pscustomobject]@{
        Id = $Id
        Path = $path
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
        Request = $request
        Commit = $commit
        Parts = @($parts.ToArray())
    }
}

function Read-AllPerfSqlFiles($Scenarios) {
    $files = @{}
    foreach ($scenario in $Scenarios) { $files[$scenario.Id] = Read-PerfSqlFile $scenario.Id $scenario.Parts }
    $files
}

function Get-NormalizedSql([string]$Sql) { ($Sql -replace "`r`n", "`n").Trim() }

function Assert-ApprovedHash([string]$Key, [string]$Text) {
    $expected = $script:PerfApprovedHashes[$Key]
    if ($null -eq $expected) { Stop-Run 'SQL_NOT_APPROVED' "'$Key' has no approved hash in perf-common.ps1." }
    $actual = Get-Sha256Hex $Text
    if ($actual -cne $expected) {
        Stop-Run 'SQL_NOT_APPROVED' "'$Key' differs from the approved text (approved $($expected.Substring(0, 12)), found $($actual.Substring(0, 12))). If docs/perf/sql was re-captured on purpose, review the new SQL and update PerfApprovedHashes in perf-common.ps1."
    }
}

# Accepts the statements of the given files (id -> file object) only if each one equals its approved hash AND passes the
# read-only grammar. Only registered statements can be sent to sqlcmd, and only registered requests may be sent to the API.
function Register-PerfStatements($SqlFiles) {
    foreach ($id in @($SqlFiles.Keys)) {
        $file = $SqlFiles[$id]
        foreach ($part in $file.Parts) {
            $key = "$id.$($part.Name)"
            $text = Get-NormalizedSql $part.Sql
            Assert-ApprovedHash $key $text
            Assert-ReadOnlySql $text
            $script:PerfStatements[$key] = $text
        }
        Assert-ApprovedHash "$id.request" $file.Request
    }
}

function Get-ApprovedStatement([string]$Id) {
    if (-not $script:PerfStatements.ContainsKey($Id)) { Stop-Run 'SQL_NOT_APPROVED' "'$Id' is not a registered, approved statement." }
    $script:PerfStatements[$Id]
}

# The statement text as the plan cache holds it, for matching in sys.dm_exec_sql_text: the inner statement of an
# sp_executesql call (or the plain statement), without the trailing semicolon, line breaks replaced by one space.
function Get-StatementNeedle([string]$PartSql) {
    $inner = $PartSql
    if ($PartSql -match "(?s)^EXEC sp_executesql N'((?:[^']|'')*)'\s*,\s*N'") { $inner = $matches[1].Replace("''", "'") }
    $inner = $inner.Trim().TrimEnd(';').Trim()
    $inner -replace "`r?`n", ' '
}

# ---- the read-only grammar (second line of defence; see the SQL policy at the top) -----------------------------------------

function Stop-NotReadOnly([string]$Reason) { Stop-Run 'SQL_NOT_READONLY' $Reason }

# Splits on ';' outside string literals. Returns $null when a literal is not closed.
function Split-SqlStatements([string]$Sql) {
    $statements = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object System.Text.StringBuilder
    $inLiteral = $false
    for ($i = 0; $i -lt $Sql.Length; $i++) {
        $c = [string]$Sql[$i]
        if ($c -eq "'") {
            if ($inLiteral -and ($i + 1) -lt $Sql.Length -and $Sql[$i + 1] -eq [char]39) { [void]$buffer.Append("''"); $i++; continue }
            $inLiteral = -not $inLiteral
        }
        elseif ($c -eq ';' -and -not $inLiteral) {
            $statements.Add($buffer.ToString().Trim())
            [void]$buffer.Clear()
            continue
        }
        [void]$buffer.Append($c)
    }
    if ($inLiteral) { return $null }
    $statements.Add($buffer.ToString().Trim())
    , @($statements.ToArray() | Where-Object { $_ -ne '' })
}

# One SELECT, with string literals blanked, free of everything that is not a plain read.
function Assert-ReadOnlyQuery([string]$Query) {
    $skeleton = [regex]::Replace($Query, "N?'(?:[^']|'')*'", '0')   # every string literal becomes the number 0; a quote left over means an unclosed literal
    if ($skeleton.Contains("'")) { Stop-NotReadOnly 'A string literal is not closed.' }
    if ($skeleton -notmatch '(?i)^\s*SELECT\b') { Stop-NotReadOnly 'A query does not start with SELECT.' }
    if ($skeleton -match '(?i)\bNEXT\s+VALUE\s+FOR\b') { Stop-NotReadOnly 'NEXT VALUE FOR changes a sequence.' }
    if ($skeleton -match '@@(?!VERSION\b|SPID\b)') { Stop-NotReadOnly 'Only @@VERSION and @@SPID may be read from the @@ functions.' }
    $denied = [regex]::Match($skeleton, '(?i)\b(INTO|USE|EXEC|EXECUTE|INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|MERGE|GRANT|REVOKE|DENY|DBCC|SHUTDOWN|BACKUP|RESTORE|BULK|OPENROWSET|OPENQUERY|OPENDATASOURCE|OPENXML|WAITFOR|KILL|RECONFIGURE|READTEXT|WRITETEXT|UPDATETEXT|PRINT|RAISERROR|THROW|DECLARE|BEGIN|COMMIT|ROLLBACK|CHECKPOINT|SET|GO|xp_\w+|sp_\w+|fn_\w+)\b')
    if ($denied.Success) { Stop-NotReadOnly "A query contains '$($denied.Value)'." }
}

function Assert-ReadOnlyStatement([string]$Statement) {
    if ($Statement -match '(?i)^SET\s+STATISTICS\s+(IO|TIME|XML)\s+ON$' -or $Statement -match '(?i)^SET\s+NOCOUNT\s+ON$') { return }
    $call = [regex]::Match($Statement, "(?is)^EXEC\s+sp_executesql\s+N'((?:[^']|'')*)'(?:\s*,\s*N'((?:[^']|'')*)'(?:\s*,\s*(.+))?)?$")
    if ($call.Success) {
        $inner = $call.Groups[1].Value.Replace("''", "'")
        $inside = Split-SqlStatements $inner
        if ($null -eq $inside -or @($inside).Count -ne 1) { Stop-NotReadOnly 'The statement inside sp_executesql is not exactly one statement.' }
        Assert-ReadOnlyQuery @($inside)[0]
        $type = '@\w+\s+[A-Za-z0-9_]+(?:\(\s*(?:\d+(?:\s*,\s*\d+)?|max)\s*\))?'
        $value = "(?:N?'(?:[^']|'')*'|-?\d+)"
        if ($call.Groups[2].Success -and $call.Groups[2].Value -notmatch "^$type(?:\s*,\s*$type)*$") { Stop-NotReadOnly 'The parameter declarations of sp_executesql are not plain "@name type" items.' }
        if ($call.Groups[3].Success) {
            if (-not $call.Groups[2].Success) { Stop-NotReadOnly 'sp_executesql has values but no declarations.' }
            if ($call.Groups[3].Value -notmatch "(?s)^@\w+\s*=\s*$value(?:\s*,\s*@\w+\s*=\s*$value)*$") { Stop-NotReadOnly 'The parameter values of sp_executesql are not plain "@name = literal" items.' }
        }
        return
    }
    if ($Statement -match '(?i)^SELECT\b') { Assert-ReadOnlyQuery $Statement; return }
    Stop-NotReadOnly 'A statement is not SET STATISTICS IO|TIME|XML ON, SET NOCOUNT ON, SELECT, or EXEC sp_executesql with a literal SELECT.'
}

# Deny by default. See the SQL policy at the top of this file for what it is and is not.
function Assert-ReadOnlySql([string]$Sql) {
    if ($Sql -cmatch '[^\x20-\x7E\r\n\t]') { Stop-NotReadOnly 'The text has non-ASCII or control characters.' }
    if ($Sql.Contains('"')) { Stop-NotReadOnly 'Double quotes are not allowed.' }
    if ($Sql -match '(?m)^\s*:') { Stop-NotReadOnly 'A line starts with ":" (a sqlcmd command such as :CONNECT, :!!, :r).' }
    if ($Sql -match '\$\(') { Stop-NotReadOnly 'A sqlcmd variable reference $(...) is not allowed.' }
    if ($Sql -match '(?mi)^\s*GO\b') { Stop-NotReadOnly 'A batch separator is not allowed.' }
    if ($Sql.Contains('--') -or $Sql.Contains('/*') -or $Sql.Contains('*/')) { Stop-NotReadOnly 'Comments are not allowed.' }
    if ($Sql -match "\[[^\[\]]*'[^\[\]]*\]") { Stop-NotReadOnly "A quote inside a bracketed identifier could hide code from this check." }
    $statements = Split-SqlStatements $Sql
    if ($null -eq $statements) { Stop-NotReadOnly 'A string literal is not closed.' }
    if (@($statements).Count -eq 0) { Stop-NotReadOnly 'The text has no statement.' }
    foreach ($statement in @($statements)) { Assert-ReadOnlyStatement $statement }
}

# ---- the SQL that may be built (all read-only) -------------------------------------------------------------------------

# One batch: the statistics switches, then the captured statement. The XML switch is only set for the one plan execution.
function Get-StatsBatch([string]$Sql, [bool]$Xml) {
    $lines = @('SET STATISTICS IO ON;', 'SET STATISTICS TIME ON;')
    if ($Xml) { $lines += 'SET STATISTICS XML ON;' }
    ($lines + $Sql) -join "`n"
}

function Get-DatasetCheckQuery {
    "SET NOCOUNT ON;`nSELECT CAST(COUNT_BIG(*) AS varchar(20)) + '|' + CAST(CHECKSUM_AGG(CHECKSUM([Id],[Title],[OrganizationName],[Status],[Priority],[AssignedTo],[CreatedAt],[UpdatedAt])) AS varchar(20)) FROM dbo.Requests;"
}

function Get-ServerVersionQuery { "SET NOCOUNT ON;`nSELECT @@VERSION;" }

# The state of the performance database that the schema step (set-index-state.ps1) checks and records, one tagged line per fact:
# target, dataset (rows and checksum, the formula of DatabaseSeeder.GetReportAsync), by_status, by_priority, bounds,
# migration, index (with every option), constraint, fk, pages (informational) and sessions. SELECT statements only.
function Get-SchemaStateQuery {
@"
SET NOCOUNT ON;
SELECT 'target|db=' + DB_NAME() + '|marker=' + CAST((SELECT COUNT(*) FROM sys.extended_properties WHERE class = 0 AND name = N'T501_PERF_DB' AND CAST(value AS nvarchar(100)) = N'RequestManagement.T-501') AS varchar(10)) + '|state=' + CAST(d.state_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT + '|readonly=' + CAST(d.is_read_only AS varchar(1)) + '|collation=' + CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128)) FROM sys.databases AS d WHERE d.name = DB_NAME();
SELECT 'dataset|rows=' + CAST(COUNT_BIG(*) AS varchar(20)) + '|checksum=' + CAST(CHECKSUM_AGG(CHECKSUM([Id],[Title],[OrganizationName],[Status],[Priority],[AssignedTo],[CreatedAt],[UpdatedAt])) AS varchar(20)) FROM dbo.Requests;
SELECT 'by_status|' + CAST([Status] AS varchar(3)) + '|' + CAST(COUNT(*) AS varchar(20)) FROM dbo.Requests GROUP BY [Status] ORDER BY [Status];
SELECT 'by_priority|' + CAST([Priority] AS varchar(3)) + '|' + CAST(COUNT(*) AS varchar(20)) FROM dbo.Requests GROUP BY [Priority] ORDER BY [Priority];
SELECT 'bounds|min_id=' + CAST(MIN([Id]) AS varchar(20)) + '|max_id=' + CAST(MAX([Id]) AS varchar(20)) + '|min_created=' + CONVERT(varchar(23), MIN([CreatedAt]), 121) + '|max_created=' + CONVERT(varchar(23), MAX([CreatedAt]), 121) + '|history_rows=' + CAST((SELECT COUNT_BIG(*) FROM dbo.RequestStatusHistory) AS varchar(20)) FROM dbo.Requests;
SELECT 'migration|' + MigrationId + '|' + ProductVersion FROM dbo.__EFMigrationsHistory ORDER BY MigrationId;
SELECT 'index|' + t.name + '|' + i.name + '|' + CAST(i.type_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT + '|unique=' + CAST(i.is_unique AS varchar(1)) + '|pk=' + CAST(i.is_primary_key AS varchar(1)) + '|fill=' + CAST(i.fill_factor AS varchar(3)) + '|padded=' + CAST(i.is_padded AS varchar(1)) + '|ignoredup=' + CAST(i.ignore_dup_key AS varchar(1)) + '|rowlocks=' + CAST(i.allow_row_locks AS varchar(1)) + '|pagelocks=' + CAST(i.allow_page_locks AS varchar(1)) + '|filter=' + CAST(i.has_filter AS varchar(1)) + '|seqkey=' + CAST(i.optimize_for_sequential_key AS varchar(1)) + '|disabled=' + CAST(i.is_disabled AS varchar(1))
  + '|keys=' + ISNULL((SELECT STRING_AGG(CAST(c.name + IIF(ic.is_descending_key = 1, ' DESC', ' ASC') AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY ic.key_ordinal)
            FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0), N'')
  + '|include=' + ISNULL((SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY c.column_id)
            FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1), N'')
  + '|compression=' + ISNULL((SELECT MAX(CAST(p.data_compression_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT) FROM sys.partitions AS p WHERE p.object_id = i.object_id AND p.index_id = i.index_id), N'')
FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
WHERE i.index_id > 0 AND t.is_ms_shipped = 0 ORDER BY t.name, i.name;
SELECT 'constraint|' + OBJECT_NAME(parent_object_id) + '|' + name FROM sys.check_constraints WHERE is_ms_shipped = 0 ORDER BY name;
SELECT 'fk|' + OBJECT_NAME(parent_object_id) + '|' + name + '|delete=' + CAST(delete_referential_action_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT FROM sys.foreign_keys WHERE is_ms_shipped = 0 ORDER BY name;
SELECT 'pages|' + t.name + '|' + i.name + '|' + CAST(SUM(s.used_page_count) AS varchar(20)) FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id JOIN sys.dm_db_partition_stats AS s ON s.object_id = i.object_id AND s.index_id = i.index_id WHERE i.index_id > 0 AND t.is_ms_shipped = 0 GROUP BY t.name, i.name ORDER BY t.name, i.name;
SELECT 'sessions|' + CAST(COUNT(*) AS varchar(10)) FROM sys.dm_exec_sessions WHERE database_id = DB_ID() AND session_id <> @@SPID;
"@
}

# table|index|type|keys|included|rows|pages, one line per index of a user table.
function Get-IndexListQuery {
@"
SET NOCOUNT ON;
SELECT t.name + '|' + i.name + '|' + CAST(i.type_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT + '|'
  + ISNULL((SELECT STRING_AGG(CAST(c.name + IIF(ic.is_descending_key = 1, ' DESC', ' ASC') AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY ic.key_ordinal)
            FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0), N'') + '|'
  + ISNULL((SELECT STRING_AGG(CAST(c.name AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY c.column_id)
            FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1), N'') + '|'
  + CAST(ISNULL(ps.row_count, 0) AS varchar(20)) + '|' + CAST(ISNULL(ps.used_page_count, 0) AS varchar(20))
FROM sys.indexes AS i
JOIN sys.tables AS t ON t.object_id = i.object_id
OUTER APPLY (SELECT SUM(p.row_count) AS row_count, SUM(p.used_page_count) AS used_page_count
             FROM sys.dm_db_partition_stats AS p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS ps
WHERE i.index_id > 0 AND t.is_ms_shipped = 0
ORDER BY t.name, i.index_id;
"@
}

# Plan hashes of the statement in the plan cache, for plans compiled in the CURRENT database only (plan attribute 'dbid' =
# DB_ID(); sqlcmd runs with -d RequestManagement_Perf), so identical statements of other databases on the server cannot
# influence the verdict. The batch of this query contains the statement text itself, so it excludes itself (and any earlier
# run of it) through the name of the view it reads.
function Get-FidelityQuery([string]$Needle) {
    $literal = $Needle.Replace("'", "''")
@"
SET NOCOUNT ON;
SELECT CONVERT(varchar(34), qs.query_plan_hash, 1) + '|' + CAST(SUM(qs.execution_count) AS varchar(20)) + '|' + CONVERT(varchar(30), MIN(qs.creation_time), 126) + '|' + CONVERT(varchar(30), MAX(qs.last_execution_time), 126)
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY (SELECT TOP (1) CONVERT(int, pa.value) AS plan_dbid FROM sys.dm_exec_plan_attributes(qs.plan_handle) AS pa WHERE pa.attribute = N'dbid') AS pdb
WHERE pdb.plan_dbid = DB_ID()
  AND CHARINDEX(N'dm_exec_query_stats', st.text) = 0
  AND CHARINDEX(N'$literal', REPLACE(REPLACE(st.text, CHAR(13), N''), CHAR(10), N' ')) > 0
GROUP BY qs.query_plan_hash;
"@
}

# The only way to obtain SQL for sqlcmd: a kind plus, where needed, the id of a registered statement.
function Get-ApprovedSql([string]$Kind, [string]$StatementId, [bool]$Xml) {
    switch ($Kind) {
        'StatsRun' { return (Get-StatsBatch (Get-ApprovedStatement $StatementId) $Xml) }
        'Fidelity' { return (Get-FidelityQuery (Get-StatementNeedle (Get-ApprovedStatement $StatementId))) }
        'DatasetCheck' { return (Get-DatasetCheckQuery) }
        'IndexListing' { return (Get-IndexListQuery) }
        'ServerVersion' { return (Get-ServerVersionQuery) }
        'SchemaState' { return (Get-SchemaStateQuery) }
    }
    Stop-Run 'SQL_NOT_APPROVED' "Unknown SQL kind '$Kind'."
}

# ---- target and sqlcmd -------------------------------------------------------------------------------------------------

# Static checks only (no process, no network): the variable is set, and it names exactly the dedicated database.
function Get-PerfTarget {
    $connectionString = [Environment]::GetEnvironmentVariable($script:PerfEnvName, 'Process')
    if ([string]::IsNullOrWhiteSpace($connectionString)) {
        Stop-Run 'ENV_MISSING' "$($script:PerfEnvName) is not set in the process environment."
    }
    $failures = @(Get-PerfTargetFailures -ConnectionString $connectionString)
    if ($failures.Count -gt 0) { Stop-Run 'TARGET_MISMATCH' ($failures -join ' ') }
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connectionString)
    if ([string]::IsNullOrEmpty($builder.UserID) -or [string]::IsNullOrEmpty($builder.Password)) {
        Stop-Run 'AUTH_UNSUPPORTED' 'The connection string needs User Id and Password (sqlcmd is called with -U and SQLCMDPASSWORD).'
    }
    $builder
}

# Sends one approved, read-only SQL text through sqlcmd. There is no parameter for SQL text: the caller names a kind and a
# registered statement. Plain runs use -W -s '|'; the plan run must not use -W (it cannot be combined with -y). -X is NOT used: it
# makes sqlcmd ignore SQLCMDPASSWORD (verified against the live container: "Login failed for user 'sa'"), and the password must
# not be on the command line. Instead the child gets SQLCMDPASSWORD and every other SQLCMD* variable (startup script SQLCMDINI,
# SQLCMDUSER, SQLCMDSERVER, ...) is removed from its environment, so nothing but the arguments below configures sqlcmd.
function Get-PerfSqlcmdEnvironment([string]$Password) {
    $environment = @{}
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if ([string]$name -like 'SQLCMD*') { $environment[[string]$name] = $null }
    }
    $environment['SQLCMDPASSWORD'] = $Password
    $environment
}

function Invoke-PerfSqlcmd {
    param(
        $Builder,
        [Parameter(Mandatory = $true)][ValidateSet('StatsRun', 'Fidelity', 'DatasetCheck', 'IndexListing', 'ServerVersion', 'SchemaState')][string]$Kind,
        [string]$StatementId,
        [string]$WorkDir,
        [switch]$Xml,
        [int]$TimeoutSeconds = 300
    )
    Assert-GuardApproved $Builder
    $sql = Get-ApprovedSql $Kind $StatementId ([bool]$Xml)
    Assert-ReadOnlySql $sql
    $file = Join-Path $WorkDir ('q-' + [guid]::NewGuid().ToString('N') + '.sql')
    Write-Utf8NoBom $file $sql
    $arguments = @('-S', $Builder.DataSource, '-U', $Builder.UserID, '-C', '-b', '-d', $script:PerfDatabase, '-t', "$TimeoutSeconds", '-h', '-1')
    if ($Xml) { $arguments += @('-y', '0', '-w', '65535') } else { $arguments += @('-W', '-s', '|') }
    $arguments += @('-i', $file)
    $run = Invoke-ChildProcess -FileName 'sqlcmd' -Arguments $arguments -ChildEnv (Get-PerfSqlcmdEnvironment $Builder.Password) -TimeoutSeconds ($TimeoutSeconds + 30)
    if ($run.TimedOut) { Stop-Run 'SQLCMD_TIMEOUT' "sqlcmd did not finish within $TimeoutSeconds s." }
    if ($run.ExitCode -ne 0) {
        $detail = (Hide-Secrets ($run.Stdout + "`n" + $run.Stderr) $Builder.Password).Trim()
        Stop-Run 'SQLCMD_FAILED' "sqlcmd exited with $($run.ExitCode). $($detail.Substring(0, [Math]::Min(600, $detail.Length)))"
    }
    $run
}

# ---- the API: environment, loopback and port ownership ---------------------------------------------------------------------

# Variables of the current process that could change how the API behaves or what it measures; they are removed for the API's
# start. PATH, TEMP and the like are not touched. Names only; values are never read.
function Get-PerfApiEnvironmentRemovals($Environment) {
    $pattern = '(?i)^(ASPNETCORE_|COMPlus_|Logging__|SummaryCache__|Kestrel__|Hosting__|ConnectionStrings__|APPSETTING_|ApplicationInsights|DOTNET_(?!ROOT|CLI_HOME|NOLOGO|CLI_TELEMETRY_OPTOUT|SKIP_FIRST_TIME_EXPERIENCE)|Urls$|AllowedHosts$)'
    @($Environment.Keys | Where-Object { $_ -match $pattern } | Sort-Object)
}

# The only address the scripts talk to: http://127.0.0.1:<port>, nothing else.
function Test-PerfLoopbackUrl([string]$Url, [int]$Port) {
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    ($uri.Scheme -eq 'http') -and ($uri.Host -ceq '127.0.0.1') -and ($uri.Port -eq $Port) -and [string]::IsNullOrEmpty($uri.UserInfo)
}

# True only when there is at least one listener and every one of them is ours, on 127.0.0.1.
function Test-ListenerOwnership($Connections, [int]$ProcessId) {
    $all = @($Connections)
    if ($all.Count -eq 0) { return $false }
    foreach ($connection in $all) {
        if ([int]$connection.OwningProcess -ne $ProcessId -or [string]$connection.LocalAddress -cne '127.0.0.1') { return $false }
    }
    $true
}

# Listeners on the port, on any address. $null when the cmdlet is not available (callers then fail closed).
function Get-PerfListeners([int]$Port) {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
    , @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

# Free on every interface: no listener reported, and a listener on the wildcard address can bind it.
function Test-PerfPortFree([int]$Port) {
    $listeners = Get-PerfListeners $Port
    if ($null -ne $listeners -and @($listeners).Count -gt 0) { return $false }
    $probe = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
    try { $probe.Start(); $probe.Stop(); $true } catch { $false }
}

# ---- parsers --------------------------------------------------------------------------------------------------------

function ConvertFrom-IndexListing([string]$Text) {
    @(($Text -split "`r?`n") | Where-Object { $_ -match '^[^|]+\|[^|]+\|[^|]+\|[^|]*\|[^|]*\|\d+\|\d+$' } | ForEach-Object {
        $f = $_ -split '\|'
        [pscustomobject]@{ Table = $f[0]; Index = $f[1]; Type = $f[2]; Keys = $f[3]; Included = $f[4]; Rows = [long]$f[5]; Pages = [long]$f[6] }
    })
}

# 'before' must have none of the five indexes, 'after' all of them.
function Assert-PhaseIndexState([string]$Phase, $Listing) {
    $present = @($Listing | Where-Object { $script:PerfIndexNames -contains $_.Index } | ForEach-Object { $_.Index })
    if ($Phase -eq 'before' -and $present.Count -ne 0) {
        Stop-Run 'PHASE_STATE_MISMATCH' "Phase 'before' needs the database without the AddQueryIndexes indexes, but these exist: $($present -join ', ')."
    }
    if ($Phase -eq 'after' -and $present.Count -ne $script:PerfIndexNames.Count) {
        $missing = @($script:PerfIndexNames | Where-Object { $present -notcontains $_ })
        Stop-Run 'PHASE_STATE_MISMATCH' "Phase 'after' needs all AddQueryIndexes indexes, but these are missing: $($missing -join ', ')."
    }
}

# STATISTICS IO / TIME output of one execution, plus a hash of the result lines so a before/after pair can be checked for equal data.
function ConvertFrom-StatsOutput([string]$Text) {
    $tables = [ordered]@{}
    foreach ($m in [regex]::Matches($Text, "(?m)^Table '([^']+)'\. Scan count (\d+), logical reads (\d+)")) {
        $name = $m.Groups[1].Value
        $previous = 0
        if ($tables.Contains($name)) { $previous = [long]$tables[$name] }
        $tables[$name] = $previous + [long]$m.Groups[3].Value
    }
    # The last 'SQL Server Execution Times' block belongs to the whole batch statement.
    $cpu = $null
    $elapsed = $null
    foreach ($m in [regex]::Matches($Text, 'SQL Server Execution Times:\s*CPU time = (\d+) ms,\s*elapsed time = (\d+) ms')) {
        $cpu = [long]$m.Groups[1].Value
        $elapsed = [long]$m.Groups[2].Value
    }
    $rows = $null
    $rowsMatch = [regex]::Match($Text, '\((\d+) rows? affected\)')
    if ($rowsMatch.Success) { $rows = [long]$rowsMatch.Groups[1].Value }

    $messageLines = New-Object System.Collections.Generic.List[string]
    $resultLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        if ($line -match "^Table '" -or $line -match '^\s*SQL Server (parse and compile time|Execution Times)' -or $line -match '^\s*CPU time = ') { $messageLines.Add($line.TrimEnd()); continue }
        if ($line -match '^\(\d+ rows? affected\)') { continue }
        $resultLines.Add($line)
    }
    $countValue = $null
    if ($resultLines.Count -ge 1 -and $resultLines[0].Trim() -match '^\d+$') { $countValue = [long]$resultLines[0].Trim() }
    [pscustomobject]@{
        LogicalReads = $tables
        CpuMs = $cpu
        ElapsedMs = $elapsed
        Rows = $rows
        ResultLineCount = $resultLines.Count
        ResultSha256 = (Get-Sha256Hex ($resultLines -join "`n"))
        CountValue = $countValue
        MessageLines = @($messageLines.ToArray())
    }
}

# Output of the plan-cache query: the rows it should produce, and every other non-empty line (which makes the verdict NOT_VERIFIED).
function ConvertFrom-FidelityOutput([string]$Text) {
    $lines = @(($Text -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
    $rows = @($lines | Where-Object { $_ -match '^0x[0-9A-Fa-f]+\|\d+\|' } | ForEach-Object {
        $f = $_ -split '\|'
        [pscustomobject]@{ Hash = $f[0]; Executions = [long]$f[1]; First = $f[2]; Last = $f[3] }
    })
    [pscustomobject]@{ Rows = $rows; Unexpected = @($lines | Where-Object { $_ -notmatch '^0x[0-9A-Fa-f]+\|\d+\|' }) }
}

# STABLE only when the plan cache holds exactly one plan hash for the statement, it equals the hash of the saved plan, and at
# least the expected number of executions were seen. Anything that cannot be established is NOT_VERIFIED, never a guess.
function Get-FidelityVerdict($Fidelity, [string]$PlanHash, [int]$MinimumExecutions) {
    if (@($Fidelity.Unexpected).Count -gt 0) { return "NOT_VERIFIED (unexpected output from the plan-cache query: $(@($Fidelity.Unexpected).Count) line(s))" }
    $rows = @($Fidelity.Rows)
    if ($rows.Count -eq 0) { return 'NOT_VERIFIED (no plan-cache entry found for the performance database)' }
    $total = ($rows | Measure-Object -Property Executions -Sum).Sum
    if ($rows.Count -gt 1 -or $rows[0].Hash -ine $PlanHash) { return 'PLAN_UNSTABLE (report as "plan unstable", not as a before/after comparison)' }
    if ($total -lt $MinimumExecutions) { return "NOT_VERIFIED (only $total of at least $MinimumExecutions executions found in the plan cache)" }
    'STABLE'
}

function Get-ShowPlans([string]$Text) {
    [regex]::Matches($Text, '(?s)<ShowPlanXML.*?</ShowPlanXML>') | ForEach-Object { $_.Value }
}

function Get-PlanHashes([string]$PlanXml) {
    [regex]::Matches($PlanXml, 'QueryPlanHash="(0x[0-9A-Fa-f]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return $sorted[[int](($n - 1) / 2)] }
    ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
}

# Nearest-rank percentile: the value at position ceil(p * n) of the sorted values.
function Get-NearestRank([double[]]$Values, [double]$P) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $rank = [Math]::Max(1, [int][Math]::Ceiling([Math]::Round($P * $sorted.Count, 9)))
    $sorted[$rank - 1]
}

function Format-Number([double]$Value, [int]$Decimals = 3) {
    [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F$Decimals}", $Value)
}

# ---- git (read-only) ------------------------------------------------------------------------------------------------

function Get-GitText([string[]]$Arguments) {
    $run = Invoke-ChildProcess -FileName 'git' -Arguments $Arguments -TimeoutSeconds 60
    [pscustomobject]@{ ExitCode = $run.ExitCode; Text = ($run.Stdout + $run.Stderr).Trim() }
}

# The captured SQL is only valid for the query code it was captured from.
function Assert-SqlFilesFresh($SqlFiles) {
    foreach ($commit in @($SqlFiles.Values | ForEach-Object { $_.Commit } | Sort-Object -Unique)) {
        $diff = Get-GitText (@('diff', '--quiet', $commit, '--') + $script:PerfQuerySourcePaths)
        if ($diff.ExitCode -ne 0) {
            Stop-Run 'SQL_STALE' "The query-shaping sources differ from commit $commit, which the captured SQL was taken from. Re-capture docs/perf/sql first (PerfSqlCaptureTests)."
        }
        $untracked = Get-GitText (@('status', '--porcelain', '--') + $script:PerfQuerySourcePaths)
        if ($untracked.Text) {
            Stop-Run 'SQL_STALE' "The query-shaping sources have uncommitted or untracked changes: $($untracked.Text)."
        }
    }
}
