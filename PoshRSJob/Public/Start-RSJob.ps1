Function Start-RSJob {
    <#
        .SYNOPSIS
            Starts a background job using runspaces.

        .DESCRIPTION
            This will run a command in the background, leaving your console available to perform other tasks. This uses
            runspaces in runspacepools which allows for throttling of running jobs. As the jobs are finished, they will automatically
            dispose of each runspace and allow other runspace jobs in queue to begin based on the throttling of the runspacepool.

            This is available on PowerShell V3 and above. By doing this, you can use the $Using: variable to take variables
            in the local scope and apply those directly into the scriptblock of the background runspace job.

        .PARAMETER ScriptBlock
            The scriptblock that holds all of the commands which will be run in the background runspace. You must specify
            at least one Parameter in the Param() to account for the item that is being piped into Start-Job.

        .PARAMETER FilePath
            This is the path to a file containing code that will be run in the background runspace job.

        .PARAMETER InputObject
            The object being piped into Start-RSJob or applied via the parameter.

        .PARAMETER Name
            The name of a background runspace job

        .PARAMETER ArgumentList
            List of values that will be applied at the end of the argument list in the Param() statement.

        .PARAMETER Throttle
            Number of concurrent running runspace jobs which are allowed at a time.

        .PARAMETER ModulesToImport
            A collection of modules that will be imported into the background runspace job.

        .PARAMETER PSSnapinsToImport
            A collection of PSSnapins that will be imported into the background runspace job.

        .PARAMETER FunctionsToImport
            A collection of functions that will be imported for use with a background runspace job.

        .NOTES
            Name: Start-RSJob
            Author: Boe Prox                

        .EXAMPLE
            Get-ChildItem -Directory | Start-RSjob -Name {$_.Name} -ScriptBlock {
                Param($Directory)
                Write-Verbose $_
                $Sum = (Get-ChildItem $Directory.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
                [pscustomobject]@{
                    Name = $Directory.Name
                    SizeMB = ([math]::round(($Sum/1MB),2))
                }
            } 
            
            Id  Name                 State           HasMoreData  HasErrors    Command
            --  ----                 -----           -----------  ---------    -------
            11  .shsh                Running         False        False        ...
            12  .ssh                 Running         False        False        ...
            13  Contacts             Running         False        False        ...
            14  Desktop              Running         False        False        ...
            15  Documents            Running         False        False        ...
            16  Downloads            Running         False        False        ...
            17  Favorites            Running         False        False        ...
            18  Links                Running         False        False        ...
            19  Music                Running         False        False        ...
            20  OneDrive             Running         False        False        ...
            21  Pictures             Running         False        False        ...
            22  Saved Games          Running         False        False        ...
            23  Searches             Running         False        False        ...
            24  Videos               Running         False        False        ...

            Get-RSJob | Receive-RSJob

            Name          SizeMB
            ----          ------
            .shsh              0
            .ssh               0
            Contacts           0
            Desktop         7.24
            Documents      83.99
            Downloads    10259.6
            Favorites          0
            Links              0
            Music       16691.89
            OneDrive     1485.24
            Pictures     1734.91
            Saved Games        0
            Searches           0
            Videos         17.19

            Description
            -----------
            Starts a background runspace job that looks at the total size of each folder. Using Get-RSJob | Recieve-RSJob shows 
            the results when the State is Completed.         

        .EXAMPLE
            $Test = 'test'
            $Something = 1..10
            1..5|start-rsjob -Name {$_} -ScriptBlock {
                Param($Object) [pscustomobject]@{
                    Result=($Object*2)
                    Test=$Using:Test
                    Something=$Using:Something
                }
            }            

            Id  Name                 State           HasMoreData  HasErrors    Command
            --  ----                 -----           -----------  ---------    -------
            76  1                    Completed       True         False        ...
            77  2                    Running         False        False        ...
            78  3                    Running         False        False        ...
            79  4                    Completed       False        False        ...
            80  5                    Completed       False        False        ...
            
            Get-RSjob | Receive-RSJob

            Result Test Something
            ------ ---- ---------
                 2 test {1, 2, 3, 4...}
                 4 test {1, 2, 3, 4...}
                 6 test {1, 2, 3, 4...}
                 8 test {1, 2, 3, 4...}
                10 test {1, 2, 3, 4...}
            
            Description
            -----------
            Shows an example of the $Using: variable being used in the scriptblock.

        .EXAMPLE
            $Test = 42
            $AnotherTest = 7
            $String = 'SomeString'
            $ProcName = 'powershell_ise'
            $ScriptBlock = {
                Param($y,$z)
                [pscustomobject] @{
                    Test = $y
                    Proc = (Get-Process -Name $Using:ProcName)
                    String = $Using:String
                    AnotherTest = ($z+$_)
                    PipedObject = $_
                }
            }

            1..5|Start-RSJob $ScriptBlock -ArgumentList $test, $anothertest
            
            Description
            -----------
            Shows an example of the $Using: variable being used in the scriptblock as well as $_ and multiple -ArgumentList parameters.

    #>
    [OutputType('PoshRS.PowerShell.RSJob')]
    [cmdletbinding(
        DefaultParameterSetName = 'ScriptBlock'
    )]
    Param (
        [parameter(Mandatory=$True,Position=0,ParameterSetName = 'ScriptBlock')]
        [ScriptBlock]$ScriptBlock,
        [parameter(Position=0,ParameterSetName = 'ScriptPath')]
        [string]$FilePath,
        [parameter(ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True)]
        [object]$InputObject,
        [parameter()]
        [object]$Name,
        [parameter()]
        $ArgumentList,
        [parameter()]
        [int]$Throttle = 5,
        [parameter()]
        [string[]]$ModulesToImport,
        [parameter()]
        [string[]]$PSSnapinsToImport,
        [parameter()]
        [string[]]$FunctionsToLoad
    )
    Begin {  
        If ($PSBoundParameters['Debug']) {
            $DebugPreference = 'Continue'
        } 
        #Write-Verbose ($MyInvocation | Out-String)
        If ($PSBoundParameters.ContainsKey('Name')) {
            If ($Name -isnot [scriptblock]) {
                $JobName = [scriptblock]::Create("Write-Output $Name")
            } Else {
                $JobName = [scriptblock]::Create( ($Name -replace '\$_','$Item'))
            }
        } Else {
            Write-Verbose "Creating default Job Name"
            $JobName = [scriptblock]::Create('Write-Output Job$($Id)')
        }
        $RunspacePoolID = [guid]::NewGuid().ToString()
        Write-Verbose "Creating runspacepool <$($RunspacePoolID)> with max threads: $Throttle"        
        $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        If ($PSBoundParameters['ModulesToImport']) {
            [void]$InitialSessionState.ImportPSModule($ModulesToImport)
        }
        If ($PSBoundParameters['PSSnapinsToImport']) {
            [void]$InitialSessionState.ImportPSSnapIn($PSSnapinsToImport,[ref]$Null)
        }
        If ($PSBoundParameters['FunctionsToLoad']) {
            Write-Verbose "Loading custom functions: $($FunctionsToLoad -join '; ')"
            ForEach ($Function in $FunctionsToLoad) {
                Try {
                    RegisterScriptScopeFunction -Name $Function
                    $Definition = Get-Content Function:\$Function -ErrorAction Stop
                    Write-Debug "Definition: $($Definition)"
                    $SessionStateFunction = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $Function, $Definition
                    $InitialSessionState.Commands.Add($SessionStateFunction) 
                } Catch {
                    Write-Warning "$($Function): $($_.Exception.Message)"
                }
            }           
        }
        $RunspacePool = [runspacefactory]::CreateRunspacePool($InitialSessionState)
        $RunspacePool.ApartmentState = 'STA'
        [void]$RunspacePool.SetMaxRunspaces($Throttle)
        If ($PSVersionTable.PSVersion.Major -gt 2) {
            $RunspacePool.CleanupInterval = [timespan]::FromMinutes(2)    
        }
        $RunspacePool.Open()
        If ($PSBoundParameters['FilePath']) {
            $ScriptBlock = [scriptblock]::Create((Get-Content $FilePath | Out-String))
        }
        $RSPObject = New-Object PoshRS.PowerShell.RSRunspacePool -Property @{
            RunspacePool = $RunspacePool
            MaxJobs = $RunspacePool.GetMaxRunspaces()
            RunspacePoolID = $RunspacePoolID
        }
        $Script:List = New-Object System.Collections.ArrayList
        If ($PSBoundParameters.ContainsKey('InputObject')) {            
            [void]$list.AddRange($InputObject)    
            $IsPipeline = $False
        } Else {
            $IsPipeline = $True
        }
    }
    Process {
        If ($IsPipeline -AND $PSBoundParameters.ContainsKey('InputObject')) {
            [void]$List.Add($InputObject)
        } Else {
            $IsPipeline = $False
        }
    }
    End {  
        $SBParamCount = @(GetParamVariable -ScriptBlock $ScriptBlock).Count
        If ($PSBoundParameters.ContainsKey('InputObject')) {
            $SBParamCount++
        }
        If ($ArgumentList.Count -ne $SBParamCount) {
            Write-Verbose 'Will use $_ in Param() Block'
            $Script:Add_ = $True
        } Else {
            $Script:Add_ = $False
        }
        #region Convert ScriptBlock for $Using:
        $PreviousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        Write-Verbose "PowerShell Version: $($PSVersionTable.PSVersion.Major)"
        Switch ($PSVersionTable.PSVersion.Major) {
            2 {
                Write-Verbose "Using PSParser with PowerShell V2"
                $UsingVariables = @(GetUsingVariablesV2 -ScriptBlock $ScriptBlock)                
                Write-Verbose "Using Count: $($UsingVariables.count)"
                Write-Verbose "$($UsingVariables|Out-String)"
                Write-Verbose "CommandOrigin: $($MyInvocation.CommandOrigin)"
                If ($UsingVariables.count -gt 0) {
                    $UsingVariableValues = @($UsingVariables | ForEach {
                        $Name = $_.Content -replace 'Using:'
                        Try {
                            If ($MyInvocation.CommandOrigin -eq 'Runspace') {
                                $Value = (Get-Variable -Name $Name).Value
                            } Else {
                                $Value = $PSCmdlet.SessionState.PSVariable.Get($Name).Value
                                If ([string]::IsNullOrEmpty($Value)) {
                                    Throw 'No value!'
                                }
                            }
                            New-Object PoshRS.PowerShell.V2UsingVariable -Property @{
                                Name = $Name
                                NewName = '$__using_{0}' -f $Name
                                Value = $Value
                                NewVarName = ('__using_{0}') -f $Name
                            }
                        } Catch {
                            Throw "Start-RSJob : The value of the using variable '$($Var.SubExpression.Extent.Text)' cannot be retrieved because it has not been set in the local session."                        
                        }
                    })

                    Write-Verbose ("Found {0} `$Using: variables!" -f $UsingVariableValues.count)
                }
                If ($UsingVariables.count -gt 0 -OR $Script:Add_) {
                    $NewScriptBlock = ConvertScriptBlockV2 $ScriptBlock -UsingVariable $UsingVariables -UsingVariableValue $UsingVariableValues           
                } Else {
                    $NewScriptBlock = $ScriptBlock
                }                
            }
            Default {
                Write-Debug "Using AST with PowerShell V3+"
                $UsingVariables = @(GetUsingVariables $ScriptBlock | Group SubExpression | ForEach {
                    $_.Group | Select -First 1
                })    
                #region Get Variable Values            
                If ($UsingVariables.count -gt 0) {
                    $UsingVar = $UsingVariables | Group SubExpression | ForEach {$_.Group | Select -First 1}  
                    Write-Debug "CommandOrigin: $($MyInvocation.CommandOrigin)"      
                    $UsingVariableValues = @(ForEach ($Var in $UsingVar) {
                        Try {
                            If ($MyInvocation.CommandOrigin -eq 'Runspace') {
                                $Value = Get-Variable -Name $Var.SubExpression.VariablePath.UserPath
                            } Else {
                                $Value = ($PSCmdlet.SessionState.PSVariable.Get($Var.SubExpression.VariablePath.UserPath))
                                If ([string]::IsNullOrEmpty($Value)) {
                                    Throw 'No value!'
                                }
                            }
                            [pscustomobject]@{
                                Name = $Var.SubExpression.Extent.Text
                                Value = $Value.Value
                                NewName = ('$__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                                NewVarName = ('__using_{0}' -f $Var.SubExpression.VariablePath.UserPath)
                            }
                        } Catch {
                            Throw "Start-RSJob : The value of the using variable '$($Var.SubExpression.Extent.Text)' cannot be retrieved because it has not been set in the local session."
                        }
                    })
                    #endregion Get Variable Values
                    Write-Verbose ("Found {0} `$Using: variables!" -f $UsingVariableValues.count)
                }
                If ($UsingVariables.count -gt 0 -OR $Script:Add_) {
                    $NewScriptBlock = ConvertScript $ScriptBlock            
                } Else {
                    $NewScriptBlock = $ScriptBlock
                }
            }
        }
        $ErrorActionPreference = $PreviousErrorAction
        #endregion Convert ScriptBlock for $Using:

        Write-Debug "ScriptBlock: $($NewScriptBlock)"
        [System.Threading.Monitor]::Enter($RunspacePools.syncroot) 
        [void]$RunspacePools.Add($RSPObject)
        [System.Threading.Monitor]::Exit($RunspacePools.syncroot) 

        If ($List.Count -gt 0) {
            Write-Debug "InputObject"
            ForEach ($Item in $list) {
                $ID = Increment                    
                Write-Verbose "Using $($Item) as pipline variable"
                $PowerShell = [powershell]::Create().AddScript($NewScriptBlock)
                $PowerShell.RunspacePool = $RunspacePool
                [void]$PowerShell.AddArgument($Item)
                If ($UsingVariableValues.count -gt 0) {
                    For ($i=0;$i -lt $UsingVariableValues.count;$i++) {
                        Write-Verbose "Adding Param: $($UsingVariableValues[$i].Name) Value: $($UsingVariableValues[$i].Value)"
                        [void]$PowerShell.AddParameter($UsingVariableValues[$i].NewVarName,$UsingVariableValues[$i].Value)
                    }
                }
                If ($PSBoundParameters.ContainsKey('ArgumentList')) {
                    If ($ArgumentList.count -eq 0) {
                        [void]$PowerShell.AddArgument($ArgumentList) 
                    } Else {
                        ForEach ($Argument in $ArgumentList) {
                            Write-Verbose "Adding Argument: $($Argument)"
                            [void]$PowerShell.AddArgument($Argument)    
                        }
                    }
                }
                $Handle = $PowerShell.BeginInvoke()
                $_JobName = If ($PSVersionTable.PSVersion.Major -eq 2) {
                    $JobName.Invoke()
                } Else {
                    $JobName.InvokeReturnAsIs()
                }
                $Object = New-Object PoshRS.PowerShell.RSJob -Property @{
                    Name = $_JobName
                    InstanceID = [guid]::NewGuid().ToString()
                    ID = $ID  
                    Handle = $Handle
                    InnerJob = $PowerShell
                    Runspace = $PowerShell.Runspace
                    Finished = $handle.IsCompleted
                    Command  = $ScriptBlock.ToString()
                    RunspacePoolID = $RunSpacePoolID
                    State = [System.Management.Automation.PSInvocationState]::Running
                }
                
                $RSPObject.LastActivity = Get-Date
                [System.Threading.Monitor]::Enter($Jobs.syncroot) 
                [void]$Jobs.Add($Object)
                [System.Threading.Monitor]::Exit($Jobs.syncroot) 
                $Object            
            }
        } Else {
            Write-Debug "No InputObject"
            $ID = Increment                    
            $PowerShell = [powershell]::Create().AddScript($NewScriptBlock)
            $PowerShell.RunspacePool = $RunspacePool
            If ($UsingVariableValues) {
                For ($i=0;$i -lt $UsingVariableValues.count;$i++) {
                    Write-Verbose "Adding Param: $($UsingVariableValues[$i].Name) Value: $($UsingVariableValues[$i].Value)"
                    [void]$PowerShell.AddParameter($UsingVariableValues[$i].NewVarName,$UsingVariableValues[$i].Value)
                }
            }
            If ($PSBoundParameters.ContainsKey('ArgumentList')) {
                If ($ArgumentList.count -eq 0) {
                    [void]$PowerShell.AddArgument($ArgumentList) 
                } Else {
                    ForEach ($Argument in $ArgumentList) {
                        Write-Verbose "Adding Argument: $($Argument)"
                        [void]$PowerShell.AddArgument($Argument)    
                    }
                }
            }
            $Handle = $PowerShell.BeginInvoke()
            $_JobName = If ($PSVersionTable.PSVersion.Major -eq 2) {
                $JobName.Invoke()
            } Else {
                $JobName.InvokeReturnAsIs()
            }
            $Object = New-Object PoshRS.PowerShell.RSJob -Property @{
                Name = $_JobName
                InstanceID = [guid]::NewGuid().ToString()
                ID = $ID  
                Handle = $Handle
                InnerJob = $PowerShell
                Runspace = $PowerShell.Runspace
                Finished = $handle.RSWaitHandle
                Command  = $ScriptBlock.ToString()
                RunspacePoolID = $RunSpacePoolID
            }
            
            $RSPObject.LastActivity = Get-Date
            [System.Threading.Monitor]::Enter($Jobs.syncroot) 
            [void]$Jobs.Add($Object)
            [System.Threading.Monitor]::Exit($Jobs.syncroot) 
            $Object        
        }      
    }
}
