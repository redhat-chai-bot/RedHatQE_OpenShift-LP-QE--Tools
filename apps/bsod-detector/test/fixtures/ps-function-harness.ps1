# Test harness for the guest PowerShell scripts; used by test_golden_image_*_reboot.py and
# test_validate_crash_settings.py.
# It never runs a guest script. It parses the script, and in `call` mode runs only one
# function definition, extracted from the syntax tree, in a runspace with an otherwise empty
# InitialSessionState (no providers or applications; its only cmdlet is Set-StrictMode, see
# below). Functions that invoke any other command or a method, or a static .NET member other
# than [math], are refused before running; reading properties of the values passed in (for
# example $array.Count) is allowed.
# `mockcall` mode additionally defines test-supplied mock functions in that runspace and only
# allows the function to call those mocks, so no file, registry or network operation is reachable.
# Set-StrictMode is provided because it only changes how the runspace evaluates code (no I/O). A
# function may call it, and when the script under test enables strict mode at its top level the
# same mode is applied before its functions run, as they inherit it on the guest. Mocks (written
# by the tests) may not replace it.
param(
    [Parameter(Mandatory)][ValidateSet('parse', 'definition', 'call', 'mockcall', 'isolation')][string]$Mode,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$FunctionName = '',
    [string]$CallsJson = '[]',
    [string]$MocksPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cmdlets the isolated runspace provides itself; functions may call them in every mode.
$runspaceCmdlets = @{ 'Set-StrictMode' = [Microsoft.PowerShell.Commands.SetStrictModeCommand] }

# Token kinds that only PowerShell 7 understands; the guest runs Windows PowerShell 5.1.
$ps7OnlyTokenKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')

function Get-ScriptAST ([string]$Path, [string]$EncodingName) {
    $tokens = $null
    $errors = $null
    if ($EncodingName -eq 'utf-8') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    } else {
        $text = [System.Text.Encoding]::GetEncoding($EncodingName).GetString([System.IO.File]::ReadAllBytes($Path))
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    }
    [pscustomobject]@{ AST = $ast; Tokens = @($tokens); Errors = @($errors) }
}

function Find-Function ($ScriptAST, [string]$Name) {
    $ScriptAST.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
}

# Refuses function bodies that could reach outside the runspace: calls of commands other than the
# runspace cmdlets, and member
# access other than static [math] members (e.g. [System.IO.File]::Exists or $x.Method()).
# With -AllowedCommands (mock names) and -AllowInstanceProperties, mock-backed functions may call
# only those mocks and read properties of the objects they return; method calls stay refused.
function Assert-PureFunction ($FunctionAST, [string[]]$AllowedCommands = @(), [switch]$AllowInstanceProperties) {
    $commands = @($FunctionAST.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $allowed = @($AllowedCommands) + @($runspaceCmdlets.Keys)
    foreach ($command in $commands) {
        if ($command.GetCommandName() -notin $allowed) { throw "refused: $($FunctionAST.Name) invokes commands: $($command.Extent.Text)" }
    }
    $members = @($FunctionAST.FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] }, $true))
    foreach ($member in $members) {
        $isMath = $member.Static -and $member.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $member.Expression.TypeName.FullName -in @('math', 'System.Math')
        $isProperty = $AllowInstanceProperties -and -not $member.Static -and $member -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]
        if (-not ($isMath -or $isProperty)) { throw "refused: $($FunctionAST.Name) accesses a member outside [math]: $($member.Extent.Text)" }
    }
}

function New-IsolatedShell {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::Create()
    foreach ($name in $runspaceCmdlets.Keys) {
        $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateCmdletEntry]::new($name, $runspaceCmdlets[$name], $null))
    }
    $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $shell
}

# The script's top-level (outside any function) Set-StrictMode statement as a canonical command, or
# nothing. Only `Set-StrictMode -Version Latest` or `-Version <number>` is accepted.
function Get-TopLevelStrictMode ($ScriptAST) {
    $commands = @($ScriptAST.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-StrictMode' }, $true))
    foreach ($command in $commands) {
        $parent = $command.Parent
        while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
        if ($parent) { continue }
        if ($command.Extent.Text -notmatch '^Set-StrictMode\s+-Version\s+(Latest|\d+(\.\d+)?)$') { throw "refused: unsupported top-level strict mode: $($command.Extent.Text)" }
        return "Set-StrictMode -Version $($Matches[1])"
    }
}

# Applies the script's top-level strict mode in the runspace, so its functions run as on the guest.
function Set-ScriptStrictMode ($Shell, $ScriptAST) {
    $strictMode = Get-TopLevelStrictMode $ScriptAST
    if ($strictMode) {
        [void]$Shell.AddScript($strictMode, $false).Invoke()
        $Shell.Commands.Clear()
    }
}

function ConvertTo-Argument ($Value) {
    if ($Value -is [System.Management.Automation.PSCustomObject] -and $Value.PSObject.Properties.Name -contains 'utc') {
        return [datetime]::Parse($Value.utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }
    $Value
}

$parsed = Get-ScriptAST $ScriptPath 'utf-8'
switch ($Mode) {
    'parse' {
        $ansi = Get-ScriptAST $ScriptPath 'windows-1252'
        [ordered]@{
            utf8Errors = $parsed.Errors.Count
            windows1252Errors = $ansi.Errors.Count
            ps7OnlyTokens = @($parsed.Tokens | Where-Object { $_.Kind.ToString() -in $ps7OnlyTokenKinds } | ForEach-Object { $_.Text })
            numberTokens = @($parsed.Tokens | Where-Object { $_.Kind -eq 'Number' } | ForEach-Object { $_.Text })
            functions = @($parsed.AST.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
            commands = @($parsed.AST.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
            # Double-quoted constants without escapes or embedded single quotes can be single-quoted.
            convertibleDoubleQuoted = @($parsed.AST.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'DoubleQuoted' -and $node.Extent.Text -notmatch "[``']" }, $true) | ForEach-Object { $_.Extent.Text })
        } | ConvertTo-Json -Compress -Depth 4
    }
    'definition' {
        $fn = Find-Function $parsed.AST $FunctionName
        [ordered]@{ found = ($null -ne $fn); text = $(if ($fn) { $fn.Extent.Text } else { '' }) } | ConvertTo-Json -Compress
    }
    'call' {
        if ($parsed.Errors.Count) { throw "parse errors in ${ScriptPath}" }
        $fn = Find-Function $parsed.AST $FunctionName
        if (-not $fn) { throw "function ${FunctionName} not found in ${ScriptPath}" }
        Assert-PureFunction $fn -AllowInstanceProperties
        $shell = New-IsolatedShell
        Set-ScriptStrictMode $shell $parsed.AST
        [void]$shell.AddScript($fn.Extent.Text, $false).Invoke()
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($call in (ConvertFrom-Json $CallsJson -NoEnumerate)) {
            $shell.Commands.Clear()
            $shell.Streams.Error.Clear()
            [void]$shell.AddCommand($FunctionName)
            foreach ($value in $call) { [void]$shell.AddArgument((ConvertTo-Argument $value)) }
            $out = @($shell.Invoke())
            if ($shell.Streams.Error.Count) { throw $shell.Streams.Error[0].Exception }
            $results.Add($out[0])
        }
        ConvertTo-Json -InputObject $results.ToArray() -Compress
    }
    'mockcall' {
        if ($parsed.Errors.Count) { throw "parse errors in ${ScriptPath}" }
        $fn = Find-Function $parsed.AST $FunctionName
        if (-not $fn) { throw "function ${FunctionName} not found in ${ScriptPath}" }
        $mocks = Get-ScriptAST $MocksPath 'utf-8'
        $mockNames = @($mocks.AST.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $shadowed = @($mockNames | Where-Object { $runspaceCmdlets.ContainsKey($_) })
        if ($shadowed.Count) { throw "refused: mocks must not replace $($shadowed -join ', ')" }
        Assert-PureFunction $fn -AllowedCommands $mockNames -AllowInstanceProperties
        $shell = New-IsolatedShell
        Set-ScriptStrictMode $shell $parsed.AST
        [void]$shell.AddScript($mocks.AST.Extent.Text, $false).Invoke()
        $shell.Commands.Clear()
        [void]$shell.AddScript($fn.Extent.Text, $false).Invoke()
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($call in (ConvertFrom-Json $CallsJson -NoEnumerate)) {
            $state = @{}
            foreach ($property in $call.state.PSObject.Properties) { $state[$property.Name] = [string[]]@($property.Value) }
            $log = [System.Collections.Generic.List[string]]::new()
            $shell.Runspace.SessionStateProxy.SetVariable('MockState', $state)
            $shell.Runspace.SessionStateProxy.SetVariable('MockLog', $log)
            $shell.Commands.Clear()
            $shell.Streams.Error.Clear()
            [void]$shell.AddCommand($FunctionName)
            foreach ($value in $call.args) {
                if ($value -is [array]) { [void]$shell.AddArgument([string[]]$value) } else { [void]$shell.AddArgument((ConvertTo-Argument $value)) }
            }
            $out = @($shell.Invoke())
            if ($shell.Streams.Error.Count) { throw $shell.Streams.Error[0].Exception }
            $results.Add([ordered]@{ output = @($out | ForEach-Object { "$_" }); log = @($log) })
        }
        ConvertTo-Json -InputObject $results.ToArray() -Compress -Depth 4
    }
    'isolation' {
        $shell = New-IsolatedShell
        $results = [ordered]@{}
        foreach ($name in (ConvertFrom-Json $CallsJson -NoEnumerate)) {
            $shell.Commands.Clear()
            $shell.Streams.Error.Clear()
            [void]$shell.AddScript("& '$name'")
            try {
                [void]$shell.Invoke()
                $results[$name] = $(if ($shell.Streams.Error.Count) { $shell.Streams.Error[0].Exception.GetType().Name } else { 'ran' })
            } catch {
                $inner = $_.Exception
                while ($inner.InnerException) { $inner = $inner.InnerException }
                $results[$name] = $inner.GetType().Name
            }
        }
        $results | ConvertTo-Json -Compress
    }
}
