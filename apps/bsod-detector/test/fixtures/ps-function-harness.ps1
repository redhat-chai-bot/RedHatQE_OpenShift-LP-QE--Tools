# Test harness for the guest PowerShell scripts; used by test_golden_image_*_reboot.py.
# It never runs a guest script. It parses the script, and in `call` mode runs only one
# function definition, extracted from the syntax tree, in a runspace with an empty
# InitialSessionState (no cmdlets, providers or applications). Functions that invoke any
# command, or any .NET member other than static [math] members, are refused before running.
param(
    [Parameter(Mandatory)][ValidateSet('parse', 'definition', 'call', 'isolation')][string]$Mode,
    [Parameter(Mandatory)][string]$ScriptPath,
    [string]$FunctionName = '',
    [string]$CallsJson = '[]'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# Refuses function bodies that could reach outside the runspace: command calls, and member
# access other than static [math] members (e.g. [System.IO.File]::Exists or $x.Method()).
function Assert-PureFunction ($FunctionAST) {
    $commands = @($FunctionAST.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    if ($commands.Count) { throw "refused: $($FunctionAST.Name) invokes commands: $($commands[0].Extent.Text)" }
    $members = @($FunctionAST.FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] }, $true))
    foreach ($member in $members) {
        $isMath = $member.Static -and $member.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $member.Expression.TypeName.FullName -in @('math', 'System.Math')
        if (-not $isMath) { throw "refused: $($FunctionAST.Name) accesses a member outside [math]: $($member.Extent.Text)" }
    }
}

function New-IsolatedShell {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::Create()
    $iss.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $shell
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
        } | ConvertTo-Json -Compress -Depth 4
    }
    'definition' {
        $fn = Find-Function $parsed.AST $FunctionName
        [ordered]@{ found = ($null -ne $fn); text = $(if ($fn) { $fn.Extent.Text } else { '' }) } | ConvertTo-Json -Compress
    }
    'call' {
        if ($parsed.Errors.Count) { throw "parse errors in $ScriptPath" }
        $fn = Find-Function $parsed.AST $FunctionName
        if (-not $fn) { throw "function $FunctionName not found in $ScriptPath" }
        Assert-PureFunction $fn
        $shell = New-IsolatedShell
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
