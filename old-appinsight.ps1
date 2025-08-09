<#
.SYNOPSIS
    Validates and compares Kubernetes pods to ensure they are sending logs to Azure Application Insights.

.DESCRIPTION
    This script performs a series of steps to ensure that the pods running in a Kubernetes cluster are correctly sending logs 
    to Azure Application Insights. It retrieves Helm chart version, extracts pod names and replica counts from Helm values, 
    checks the currently running pods in the specified Kubernetes namespace, and verifies which of these are configured to 
    send logs to Application Insights. The script also identifies discrepancies and generates alerts if any expected pods 
    are not in the running state or are not sending logs to Application Insights.

    # The name of the Azure Container Registry (ACR) to be used.
    .PARAMETER ACRName
    Mandatory [string] 

    # Path to the customer configurations repo 
    .PARAMETER configPath
    Mandatory [string]

    # The name of the customer for whom the script is being run.
    .PARAMETER customerName
    Mandatory [string]

    # Path to the Kubernetes configuration file (kubeconfig) used for connecting to the cluster.
    .PARAMETER kubeConfig
    Mandatory [string]

    # Path to the Python script that will be executed as part of the common logging process.
    .PARAMETER pythonScriptPath
    Mandatory [string]

    # Use cases for the dispatch product.
    .PARAMETER dispatchuseCase
    Mandatory [string]
    
    # Names of Application Insights resources used for monitoring and logging.
    .PARAMETER dispatchappInsightName
    Mandatory [string]

    # Namespaces in the Kubernetes cluster that are being used for dispatch.
    .PARAMETER dispatchNamespace
    Mandatory [string]

    # Resource groups associated with the customer for deployment.
    .PARAMETER dispatchcustomerResourceGroup
    Mandatory [string]
#>

param (

    [string][Parameter(Mandatory = $true)] $ACRName,

    [string][Parameter(Mandatory = $true)] $configPath, 

    [string][Parameter(Mandatory = $true)] $customerName, 

    [string][Parameter(Mandatory = $true)] $kubeConfig, 
    
    [string][Parameter(Mandatory = $true)] $pythonScriptPath, 

    [string][Parameter(Mandatory = $true)] $dispatchuseCase,

    [string][Parameter(Mandatory = $true)] $dispatchappInsightName,

    [string][Parameter(Mandatory = $true)] $dispatchNamespace,

    [string][Parameter(Mandatory = $true)] $dispatchcustomerResourceGroup

)

$workspacePath = $env:PIPELINE_WORKSPACE
$env:KUBECONFIG = "$kubeConfig"
$yamlFilePattern1 = "*-deployment.yaml"
$yamlFilePattern2 = "*-deployment.yml"

[string[]]$dispatchuseCase = $dispatchuseCase -split ','
[string[]]$dispatchNamespace = $dispatchNamespace -split ','
[string[]]$dispatchcustomerResourceGroup = $dispatchcustomerResourceGroup -split ','
[string[]]$dispatchappInsightName =  $dispatchappInsightName -split ','

[int]$totalindex = $dispatchuseCase.Count
<#
.SYNOPSIS
    Retrieves the Helm chart version from a specified `dispatchParameters.json` file.

.DESCRIPTION
    This function searches for the `dispatchParameters.json` file within a given path that is constructed based on the provided `configPath`, `customerName`, and `dispatchUseCase`. 
    It reads the JSON content from the file, extracts the Helm chart version, and returns the version with '+' characters replaced by '_'. 
    If the file or path is not found, or if there are issues reading the file, appropriate errors or warnings are thrown.

.PARAMETER configPath
    The base directory path where the configuration files are stored. This is the root path under which customer-specific directories are located.

.PARAMETER customerName
    The name of the customer whose Helm chart version you want to retrieve. This will be used to locate the correct directory within the base `configPath`.

.PARAMETER dispatchUseCase
    The specific use case associated with the customer for which the Helm chart version is required. This will further refine the search path.

.EXAMPLE
    getHelmChartVersion -configPath "C:\Configs" -customerName "CustomerA" -dispatchUseCase "UseCase1"
    Returns the Helm chart version from the `dispatchParameters.json` file located in "C:\Configs\CustomerA\UseCase1".
#>

function getHelmChartVersion {
    param (
        [string]$configPath,
        [string]$customerName,
        [string]$dispatchuseCase
    )
    
    # Check if the base path exists
    if (-not (Test-Path -Path $configPath -PathType Container)) {
        python $pythonScriptPath log_message --message "Base path not found" --log_type "ERROR"
        throw "Base path not found: $configPath"

    }

    # Validate if the customer directory exists
    $customerPath = Join-Path -Path $configPath -ChildPath $customerName
    if (-not (Test-Path -Path $customerPath -PathType Container)) {
        python $pythonScriptPath log_message --message "Customer not found or invalid" --log_type "ERROR"
        throw "Customer not found or invalid: $customerName"
    }
    
    $path = Join-Path -Path $configPath -ChildPath "$customerName/$dispatchuseCase"
    if (-not (Test-Path -Path $path -PathType Container)) {
        python $pythonScriptPath log_message --message "Use case path not found" --log_type "ERROR"
        throw "Use case path not found: $path"

    }

    $files = Get-ChildItem -Path $path -Filter "dispatchParameters.json" -Recurse
    if ($files.Count -eq 0) {
        python $pythonScriptPath log_message --message "No dispatchParameters.json files found in path" --log_type "ERROR"
        throw "No dispatchParameters.json files found in path: $path"
    }

    $version = @()
    foreach ($file in $files) {
        try {
            # Check if the file exists
            if (-not (Test-Path -Path $file.FullName -PathType Leaf)) {
                python $pythonScriptPath log_message --message "File not found: $($file.FullName)" --log_type "ERROR"
                throw "File not found: $($file.FullName)"
            }

            $jsonContent = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json

            if ($null -ne $jsonContent.parameters.dispatchHelmChartVersion -and
                $null -ne $jsonContent.parameters.dispatchHelmChartVersion.value) {
                $dispatchHelmChartVersionValue = $jsonContent.parameters.dispatchHelmChartVersion.value
                # Replace "+" with "_" in the version string
                $dispatchHelmChartVersionValue = $dispatchHelmChartVersionValue -replace '\+', '_'
                $version += $dispatchHelmChartVersionValue
            }
        }
        catch {
            Write-Warning "Failed to process file $($file.FullName): $_"
            python $pythonScriptPath log_message --message "Failed to process file $file" --log_type "ERROR"
        }
    }

    return $version
}
<#
.SYNOPSIS
    Extracts pod names and their replicas count from a nested hashtable or PSCustomObject structure.

.DESCRIPTION
    This function recursively processes a hashtable or PSCustomObject to extract pod names and their replica counts. It filters entries based on the 'enabled' and 'replicas' properties. The results are stored in a reference hashtable provided as an argument.

.PARAMETER data
    The input data, provided in a hashtable or PSCustomObject format, containing the configuration details. This typically includes pod names and associated properties like 'enabled' and 'replicas'.

.PARAMETER results
    A reference to a hashtable that will store the results of the extraction process. The hashtable will contain pod names as keys and their corresponding replica counts as values.
#>
function ExtractPodNames {
    param (
        [hashtable]$data,        
        [ref]$results            
    )
    
    # Validate 'data' parameter
    if ($null -eq $data -or -not ($data -is [System.Collections.Hashtable] -or $data -is [System.Management.Automation.PSCustomObject])) {
        python $pythonScriptPath log_message --message "Invalid input: 'data' must be a hashtable or PSCustomObject" --log_type "ERROR"
        throw "Invalid input: 'data' must be a hashtable or PSCustomObject."
    }
    # Validate 'results' parameter
    if ($null -eq $results -or -not ($results.Value -is [System.Collections.Hashtable])) {
        python $pythonScriptPath log_message --message "Invalid input: 'results' must be a reference to a hashtable" --log_type "ERROR"
        throw "Invalid input: 'results' must be a reference to a hashtable."
    }
    
    # Iterate over each key in the data
    foreach ($key in $data.Keys) {
        $item = $data[$key]
        
        # Process only if the item is a hashtable or PSCustomObject
        if ($item -is [System.Collections.Hashtable] -or $item -is [System.Management.Automation.PSCustomObject]) {
            # Handle the 'tracker' pod case
            if ($key -eq 'tracker') {
                if ($item.ContainsKey('enabled') -and $item.enabled -eq $true) {
                    # Process the main tracker pod's replicas
                    if ($item.ContainsKey('replicas')) {
                        $results.Value[$key] = $item.replicas
                    }
                    
                    # Process the instances under 'tracker'
                    if ($item.ContainsKey('instances')) {
                        foreach ($instance in $item.instances) {
                            if ($instance -is [System.Collections.Hashtable] -or $instance -is [System.Management.Automation.PSCustomObject]) {
                                $instanceKey = $instance.Keys | Where-Object { $_ -eq 'cadpf' }
                                if ($instanceKey -and $null -ne $instance[$instanceKey]) {
                                    $instanceName = $instance[$instanceKey]
                                    if ($instance.ContainsKey('replicas')) {
                                        $instanceReplicas = $instance.replicas
                                    } else {
                                        $instanceReplicas = 1
                                    }
                                    $results.Value["tracker-$instanceName"] = $instanceReplicas
                                }
                            }
                        }
                    }
                }
                continue
            }

            # Retrieve the 'enabled' and 'replicas' properties
            $enabled = if ($item.ContainsKey('enabled')) { $item.enabled } else { $null }
            $hasReplicas = $item.ContainsKey('replicas')
            
            # Check the 'enabled' property and replica availability
            if ($enabled -eq $false) {
                continue
            }
            elseif ($null -eq $enabled -or $enabled -eq $true) {
                if ($hasReplicas) {
                    $results.Value[$key] = $item.replicas
                }
            }
            elseif (-not $item.ContainsKey('enabled') -and $hasReplicas) {
                $results.Value[$key] = $item.replicas
            }
            
            # Recursively process nested hashtables or PSCustomObjects
            ExtractPodNames -data $item -results ([ref]$results.Value)
        }
    }
}
<#
.SYNOPSIS
    Function to read the deployment YAML files within the templates directory and compare them with the extracted pod names.

.DESCRIPTION
    - Recursively searches for 'templates' directories within the provided Helm chart path.
    - Reads YAML files that match the specified file name patterns.
    - For each YAML file, matches the file prefix with extracted pod names and processes the file to find deployment names and replicas.
    - Checks if the content contains 'appinsights.secrets' and includes the deployment name and replica count in the final results.
    - Processes 'baseapp' pods directly from the Helm values YAML file and includes their names and replicas in the final results.
    - Processes 'informer' related pods by checking specific conditions in the Helm values YAML file and includes them in the final results.
    - The final results are returned as a hashtable with deployment names as keys and replica counts as values.

.PARAMETER HelmChartPath
    The path to the Helm chart directory where the search will be conducted.

.PARAMETER YamlFileNamePattern1
    The first pattern for YAML file names to search for within the 'templates' directory.

.PARAMETER YamlFileNamePattern2
    The second pattern for YAML file names to search for within the 'templates' directory.

.PARAMETER extractedPodNames
    A hashtable of extracted pod names and their corresponding replica counts, which will be compared with the YAML file names.

.PARAMETER HelmValuesYaml
    A hashtable of Helm values extracted from the YAML file, used to process 'baseapp' and 'informer' related pods.
#>

function getPodsByHelmChartPath {
    param (
        [string]$HelmChartPath,
        [string]$YamlFileNamePattern1,
        [string]$YamlFileNamePattern2,
        [hashtable]$ExtractedPodNames,
        [hashtable]$HelmValuesYaml
    )

    # Validate if extractedPodNames is null or empty
    if (-not $ExtractedPodNames -or $ExtractedPodNames.Count -eq 0) {
        Write-Warning "ExtractedPodNames is null or empty."
        python $pythonScriptPath log_message --message "ExtractedPodNames is null or empty" --log_type "ERROR"
        return @{}
    }

    $finalResults = @{}
    $baseAppPods = @()
    $informerPods = @()

    try {
        # Get all 'templates' directories within the Helm chart path
        $templatesDirectories = Get-ChildItem -Path $HelmChartPath -Recurse -Directory | Where-Object { $_.Name -eq 'templates' }

        foreach ($templatesDir in $templatesDirectories) {
            # Get YAML files matching the specified patterns
            $files = Get-ChildItem -Path $templatesDir.FullName -Filter $YamlFileNamePattern1 -File
            $files += Get-ChildItem -Path $templatesDir.FullName -Filter $YamlFileNamePattern2 -File

            foreach ($file in $files) {
                $fileContent = Get-Content -Path $file.FullName -Raw
                $filePrefix = ($file.BaseName -replace '(^[^-]+)-.*$', '$1')
                $deploymentName = $null
                $inMetadata = $false
                $lines = $fileContent -split "`n"

                foreach ($prefix in $extractedPodNames.Keys) {
                    # Check if the file prefix matches the pod prefix
                    if (($filePrefix -eq $prefix) -or
                        ($prefix -eq 'changepub' -and $filePrefix -eq 'changepublisher') -or
                        ($prefix -eq 'facilityCommands' -and $filePrefix -eq 'facilcmds') -or
                        ($prefix -eq 'calltaker' -and $filePrefix -eq 'calltakermodule') -or 
                        ($prefix -eq 'cadlink' -and $filePrefix -eq 'cadlinkmodule')) {
                        
                        # Iterate through the lines to find the deployment name
                        foreach ($line in $lines) {
                            if ($line -match 'metadata:') {
                                $inMetadata = $true
                            } elseif ($inMetadata -and $line -match 'name:\s*(\S+)') {
                                $deploymentName = $matches[1]
                                if ($deploymentName -match '^[a-zA-Z0-9\-]+$') {
                                    break
                                } else {
                                    $deploymentName = $null
                                }
                            }
                        }

                        if (-not $deploymentName) {
                            continue
                        }

                        # Check for 'appinsights.secrets' in the file content
                        if ($fileContent -match 'appinsights.secrets') {
                            if ($prefix -eq 'recommendUnit') {
                                # Process the recommendUnit pod's replicas if 'enabled' is null or true and has replicas
                                $recommendUnitData = $HelmValuesYaml['recommendUnit']
                                # Check if there are instances
                                if ($recommendUnitData.ContainsKey('instances')) {
                                    foreach ($instance in $recommendUnitData.instances) {
                                        if ($instance -is [System.Collections.Hashtable] -or $instance -is [System.Management.Automation.PSCustomObject]) {
                                            if ($instance.ContainsKey('config')) {
                                                $configName = $instance.config
                                                $instanceReplicas = if ($instance.ContainsKey('replicas')) { $instance.replicas } else { 1 }
                                                $finalResults["recmndunit-$configName"] = $instanceReplicas
                                            }
                                        }
                                    }
                                }
                                # If there are No instances
                                elseif (-not $recommendUnitData.ContainsKey('instances')) {  
                                    foreach ($key in $recommendUnitData.Keys) {
                                        $value = $recommendUnitData[$key]
                                        if ($key -eq 'replicas') { $replicas = $recommendUnitData[$key]}
                                        if ($key -eq 'saveLogs'){
                                            if($value -eq $true) {
                                                # If value is true, one each replicas of recmndunit & recmndunitl
                                                $finalResults["recmndunit"] = 1
                                                $finalResults["recmndunitl"] = 1
                                            } 
                                            else{
                                                # If value is false, given replicas of recmndunit
                                                $finalResults["recmndunit"] = $replicas
                                            }
                                        }
                                    }
                                }
                            } elseif ($filePrefix -eq 'tracker') {
                                # Add tracker pods directly with their replicas
                                foreach ($key in $extractedPodNames.Keys) {
                                    if ($key -like 'tracker-*') {
                                        $finalResults[$key] = $extractedPodNames[$key]
                                    }
                                }
                            }elseif ($prefix -eq 'cadLink' -or $prefix -eq 'fireLink') {
                                # Check if there are instances for cadLink or fireLink
                                if ($HelmValuesYaml[$prefix].ContainsKey('instances') -and $HelmValuesYaml[$prefix].instances) {
                                    # Directly print the pod names from extractedPodNames
                                    foreach ($instance in $HelmValuesYaml[$prefix].instances) {
                                        if ($instance.ContainsKey('configurationName')) {
                                            $instanceName = $instance.configurationName
                                            $instanceReplicas = if ($instance.ContainsKey('replicas')) { $instance.replicas } else { 1 }
                                            $finalResults["$prefix$instanceName"] = $instanceReplicas
                                        }
                                    }
                                } else {
                                    # Print the deployment name if no instances
                                    $finalResults[$deploymentName] = $extractedPodNames[$prefix]
                                }
                            }
                             else {
                                $finalResults[$deploymentName] = $extractedPodNames[$prefix]
                            }
                        }
                    }
                }

                # Process baseapp pods
                if ($filePrefix -eq 'baseapp') {
                    if ($HelmValuesYaml.ContainsKey('baseapp')) {
                        $baseappPodsHashtable = $HelmValuesYaml['baseapp']
                        foreach ($podKey in $baseappPodsHashtable.Keys) {
                            $podData = $baseappPodsHashtable[$podKey]
                            if ($podData -is [System.Collections.Hashtable]) {
                                $enabled = if ($podData.ContainsKey('enabled')) { $podData['enabled'] } else { $null }
                                $replicas = if ($podData.ContainsKey('replicas')) { $podData['replicas'] } else { $null }

                                if ($enabled -eq $null -or $enabled -eq $true) {
                                    $baseAppPods += [PSCustomObject]@{
                                        Name      = $podKey
                                        Replicas  = $replicas
                                    }
                                }
                            }
                        }
                    }
                }

                # Process informer-related pods
                if ($HelmValuesYaml.ContainsKey('informer')) {
                    [hashtable]$informerPodsHashtable = $HelmValuesYaml['informer']
                    if ($informerPodsHashtable.ContainsKey('coreReplicas') -and $informerPodsHashtable.coreReplicas -ne $null) {
                        $informerPods += [PSCustomObject]@{
                            Name      = 'informer-core'
                            Replicas  = $informerPodsHashtable.coreReplicas
                        }
                    }

                    $providerProperties = @('commSysProvider', 'rabbitMqProvider', 'webrmsProvider')
                    foreach ($providerProperty in $providerProperties) {
                        if ($informerPodsHashtable.ContainsKey($providerProperty) -and $informerPodsHashtable[$providerProperty] -eq $true) {
                            $baseName = $providerProperty -replace 'Provider$', ''
                            $replicasProperty = "${baseName}Replicas"
                            if ($providerProperty -eq 'commSysProvider') {
                                $informerPods += [PSCustomObject]@{
                                    Name      = "informer-comSys"
                                    Replicas  = $informerPodsHashtable[$replicasProperty]
                                }
                            } else {
                                $informerPods += [PSCustomObject]@{
                                    Name      = "informer-$baseName"
                                    Replicas  = $informerPodsHashtable[$replicasProperty]
                                }
                            }
                        }
                    }
                }

                # Add informer pods with 'appinsights.secrets' to final results
                foreach ($informerPod in $informerPods) {
                    $informerPrefix = ($informerPod.Name -split '-')[0,1] -join '-'
                    if ($file.BaseName -match "$informerPrefix") {
                        foreach ($line in $lines) {
                            if ($line -match 'metadata:') {
                                $inMetadata = $true
                            } elseif ($inMetadata -and $line -match 'name:\s*(\S+)') {
                                $deploymentName = $matches[1]
                                if ($deploymentName -match '^[a-zA-Z0-9\-]+$') {
                                    break
                                } else {
                                    $deploymentName = $null
                                }
                            }
                        }

                        if ($deploymentName -and $fileContent -match 'appinsights.secrets') {
                            $replicas = $informerPod.Replicas
                            $finalResults[$deploymentName] = $replicas
                        }
                    }
                }
            }
        }

        # Add baseapp pods to final results
        foreach ($pod in $baseAppPods) {
            $finalResults[$pod.Name] = $pod.Replicas
        }

        return [hashtable]$finalResults
    }
    catch {
        Write-Warning "Failed to retrieve YAML files from Helm chart path: $HelmChartPath. $_"
        python $pythonScriptPath log_message --message "Failed to retrieve YAML files from Helm chart path:" --log_type "ERROR"
        return @{}
    }
}

<#
.SYNOPSIS
    Retrieves the names of running pods in a specified Kubernetes namespace.

.DESCRIPTION
    This function uses `kubectl` to check if a specified namespace exists and retrieves the names of all running pods within that namespace. 
    It filters pods by their status phase being "Running" and returns their names.

.PARAMETER dispatchNamespace
    Name of the Kubernetes dispatch namespace to retrieve running pods 
#>

function getRunningPods {
    param (
        [string][Parameter(Mandatory = $true)] $dispatchNamespace  
    )
    try {
        # Verify if the specified namespace exists
        $verifyNamespace = kubectl get namespace $dispatchNamespace -o name

        if (-not $verifyNamespace) {
            Write-Warning  "Namespace '$dispatchNamespace' not found."
            python $pythonScriptPath log_message --message "Namespace '$dispatchNamespace' not found." --log_type "ERROR"
        }
        # Retrieve running pods in the specified namespace
        $runningPods = kubectl get pods -n $dispatchNamespace --field-selector=status.phase=Running -o=json 
        $podNames = ($runningPods | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name }
	    Write-Host "[group]"
        Write-Host "[debug] RunningPods: "$podNames.Count""
        Write-Host "[command]---------------------------------------------------------------------------------"
        $podNames | ForEach-Object { Write-Host "[section] $_" } | Sort-Object
        Write-Host "[endgroup]"
        
        if ($podNames.Count -eq 0) { 
            python $pythonScriptPath log_message --message "No Running Pods Founds:" --log_type "ERROR"
            Write-Warning  "No Running Pods Found" 
        }

        # Return the names of running pods
        return $podNames
    }
    catch {
        Write-Warning "Exception While Fetching Running Pods: $($_.Exception.Message)"
        python $pythonScriptPath log_message --message "Exception While Fetching Running Pods:" --log_type "WARNING"
    }
}

<#
.SYNOPSIS
    Retrieves a list of cloud role instances (pods) from Azure Application Insights.

.DESCRIPTION
    This function queries Azure Application Insights to retrieve unique cloud role instances from various telemetry types (availability results, requests, exceptions, etc.).
    It uses the Azure CLI to perform the query and returns the names of the cloud role instances (pods).

.PARAMETER appinsightName
    Name of the Application Insights resource

.PARAMETER resourceGroup
    Name of the resource group containing the Application Insights resource
#>
function getAiPods {
    param (
        [string][Parameter(Mandatory = $true)] $appinsightName, 

        [string][Parameter(Mandatory = $true)] $resourceGroup 
    )

    try {
        
        # Query Azure Application Insights to get cloud role instances
        # union Combines the results of multiple tables into a single result set.
        # isfuzzy=true: Enables fuzzy matching for the query. This allows the query to return results that are similar to the specified values.
        # requests, traces, dependencies: These tables contain data about requests, traces, and dependencies in the Application Insights resource.
        # where timestamp >= ago(10m): Filters the results to only include data from the last 10 minutes.
        # distinct cloud_RoleInstance: Returns a distinct list of cloud role instances (pods) from the filtered data.
        
        $aicloudroleinstnaces = az monitor app-insights query `
            --app $appinsightName `
            --analytics-query "customMetrics | where timestamp >= ago(30min) | distinct cloud_RoleInstance" `
            --resource-group $resourceGroup

        # Extract and return cloud role instances (pods) from the query result
        $resultPods = ($aicloudroleinstnaces | ConvertFrom-Json).tables[0].rows | ForEach-Object { $_[0] }

        if ($resultPods.Count -eq 0) { 
            Write-Warning "No Pods Found In AI With CustomMetric Configured"
            python $pythonScriptPath log_message --message "No Pods Found In AI With CustomMetric Configured" --log_type "ERROR"
        }

        Write-Host "[group]"
        Write-Host "[debug]Pods Configured With CustomMetric : "$resultPods.Count""
        Write-Host "[command]---------------------------------------------------------------------------------"
        $resultPods | ForEach-Object { Write-Host "[section] $_" } | Sort-Object
        Write-Host "[endgroup]"

        return $resultPods
    }
    catch {
        # Log an error message and exit with a non-zero status code in case of failure
        Write-Warning "Error reading pods from cloud role instances: $_"
        python $pythonScriptPath log_message --message "Error reading pods from cloud role instances" --log_type "ERROR"
       
    }    
}

<#
.SYNOPSIS
    Compares expected pods with currently running pods to identify discrepancies.

.DESCRIPTION
    This function compares the list of pods that should be running (from a hashtable) with the currently running pods (from an array).
    It identifies which expected pods are running and which are not, providing a warning for critical missing pods.

.PARAMETER shouldbePods
    Hashtable of expected pods and their replica counts

.PARAMETER runningPods
    Array of currently running pods
#>

function getCompareBaseRunningPods {
    param (
        [hashtable]$shouldbePods, 
        [string[]]$runningPods
    )
    try {
        # Initialize empty arrays for storing matching and non-matching pods
        $matchList = @()
        $noMatchList = @()
        $sumNotFoundCount = 0

        # Iterate through each key in $shouldbePods
        foreach ($key in $shouldbePods.Keys) {
            # Get the expected number of pods for each prefix
            $count = $shouldbePods[$key]

            # Find running pods that match the prefix
            $matchingItems = $runningPods | Where-Object { $_ -like "$key-*" } | Select-Object -First $count
            # Count the number of matching items found
            $foundCount = $matchingItems.Count

            # Add found items to the matchList
            $matchList += $matchingItems 
            # If not enough matches were found, calculate the missing count and add to noMatchList
            if ($foundCount -lt $count) {
                $notFoundCount = $count - $foundCount
                $noMatchList += "$notFoundCount OF $count Replicas not Running - $key"
                $sumNotFoundCount += $notFoundCount      
            }
        }
        if($sumNotFoundCount -eq 0){
            Write-Host "[section] ALL CONFIGURED PODS ARE IN RUNNING STATE "
            python $pythonScriptPath log_message --message "ALL CONFIGURED PODS ARE IN IN RUNNING STATE" --log_type "INFO"

        }
        else{
            # Log a warning message and use Python script to log an alert message
            Write-Host "[warning]------------ CONFIGURED PODS NOT IN RUNNING STATE: $sumNotFoundCount ------------------"

            $noMatchList | ForEach-Object { Write-Host "[command] $_ " }
            python $pythonScriptPath log_message --message "CONFIGURED PODS NOT IN RUNNING STATE $noMatchList" --log_type "ERROR"
        }
	    # Return both matching and non-matching pods as an array
        return @($matchList, $noMatchList, $sumNotFoundCount)
    }
    catch {
        Write-Warning "Error Comparing Pods: $($_.Exception.Message)"
        python $pythonScriptPath log_message --message "Error Comparing Pods:" --log_type "ERROR"

    }
}

<#
.SYNOPSIS
    Compares the list of configured pods with the list of pods monitored by Application Insights.

.DESCRIPTION
    This function identifies which configured pods are successfully sending logs to Application Insights and which are not.
    It generates a report of available and unavailable pods, highlighting any discrepancies.

.PARAMETER comparePods
    Array of pods to compare with Application Insights

.PARAMETER aiPods
    Array of pods monitored by Application Insights

.PARAMETER totalpods
    Total no Confgigured pods
#>

function getFinalPods {
    param (
        [Object[]]$comparePods, 
        [Object[]]$aiPods,
        [int]$totalpods 
    )
    try {
        # Find pods that are configured and also monitored by Application Insights
        $available = $comparePods | Where-Object { $_ -in $aiPods }

        # Find pods that are configured but not monitored by Application Insights
        $unavailable = $comparePods | Where-Object { !($_ -in $aiPods) }

        if ($available.Count -eq 0) {
            python $pythonScriptPath log_message --message "NONE OF THE PODS ARE INGESTING LOGS" --log_type "ERROR"
            throw "NONE OF THE PODS ARE INGESTING LOGS"
        }
        else{
            # Output the number of pods successfully ingesting logs
            Write-Host "[section]---------------------- NUMBER OF PODS INGESTING LOGS TO AI: $($available.Count) ------------------"

            $available = $available | Sort-Object
            $available | ForEach-Object { Write-Host "[section]$_" }
            python $pythonScriptPath log_message --message "PODS INGESTING LOGS TO AI: $available" --log_type "INFO"
        }

        # If there are unavailable pods
        if ($available.Count -eq $totalPods) {
            Write-Host "[section]All Pods are Ingesting Logs"
            python $pythonScriptPath log_message --message "ALL PODS ARE INGESTING LOGS TO AI: $available" --log_type "INFO"            
        }

        elseif ($unavailable.Count -ne 0){
            Write-Host "[warning]------------ NUMBER OF PODS NOT INGESTING LOGS TO AI: $($unavailable.Count) ---------------"                 
            
            $unavailable = $unavailable | Sort-Object
            $unavailable | ForEach-Object { Write-Host "[warning]$_" }
            python $pythonScriptPath log_message --message "PODS NOT INGESTING LOGS TO AI: $unavailable" --log_type "ERROR"
        }
        
        # Return the arrays of available and unavailable pods
        return @($available.Count, $unavailable.Count)
    }
    catch {
        Write-Warning "An error occurred while checking FinalPods: $($_.Exception.Message)"
        python $pythonScriptPath log_message --message "Failed to retrieve ACR access token for registry" --log_type "ERROR"

    }
}

function cleanFileContent {
    param (
        [string]$inputFilePath,
        [string]$outputFilePath
    )

    # Read the content of the temporary file
    $content = Get-Content -Path $inputFilePath

    # Clean the content by removing unnecessary sections (e.g., "[section]")
    $cleanedContent = $content`
        -replace "\[section\]", "" `
        -replace "\[debug\]", "" `
        -replace "\[command\]", "" `
        -replace "\[endgroup\]", "" `
        -replace "\[group\]", "" `
        -replace "\[warning\]", "" `
        -replace "\[#\]", "" `
        -replace "\[PowerShell transcript end\]", "" `
        -replace "End time:.*(\r?\n|$)", "" `
        -replace "^\s*[\r\n]+", ""

        # Save the cleaned content to the final file (or upload it if needed)
    Set-Content -Path $outputFilePath -Value $cleanedContent
}
#main function
python $pythonScriptPath log_task_start --task_name "AppInsight Pod Log Validation"

try {
    
    $logFile = "$workspacePath/AppInsightLogValidation_ACR_Login.log"
    Start-Transcript -Path $logFile -Append > $null 2>&1
    Set-Content -Path $logFile -Value ""

    # Check if ACR name is provided
    if (-not $ACRName) {
        python $pythonScriptPath log_message --message "ACR name is not provided." --log_type "ERROR"
        throw "ACR name is not provided."
    }

    # Retrieve ACR access token for logging into the Helm registry
    $accessToken = & az acr login --name $ACRName --expose-token --output tsv --query accessToken
    python $pythonScriptPath log_message --message "Failed to retrieve ACR access token for registry" --log_type "ERROR"
    if (-not $accessToken) {
        python $pythonScriptPath log_message --message "Failed to retrieve ACR access token for registry" --log_type "ERROR"
        throw "Failed to retrieve ACR access token for registry: $ACRName."
    }

    # Convert the access token to a secure string
    $secureAccessToken = $accessToken | ConvertTo-SecureString -AsPlainText -Force
    
    # Helm registry login to ACR
    $loginServer = "$ACRName"
    helm registry login $loginServer --username 00000000-0000-0000-0000-000000000000 --password $accessToken
    Write-Host "---------------------------------------------------------------------------------"
    Write-Host "[section]                       ACR LOGIN SUCCESSFUL: $ACRName"
    Write-Host "---------------------------------------------------------------------------------"
    Stop-Transcript > $null 2>&1
    cleanFileContent -inputFilePath $logFile -outputFilePath $logFile
    if($totalindex -gt 0)
    {
        foreach($UseCase in $dispatchuseCase)
        {   
            #To Handle Current Usecase and to Move to next Usecase
            $logFile = "$workspacePath/AppInsightLogValidation_$UseCase.log"
            Start-Transcript -Path $logFile -Append > $null 2>&1
            Set-Content -Path $logFile -Value ""
            try{

                Write-Host "##[group]----------------------------- Beginning UseCase $UseCase -----------------------------"
                python $pythonScriptPath log_message --message "Beginning UseCase $UseCase" --log_type "INFO"
                


                if($currentindex -lt $totalindex){   
                    $namespace = $dispatchNamespace | Where-Object {$_ -match ".*($UseCase).*"}
                    $resourcegroupName = $dispatchcustomerResourceGroup | Where-Object {$_ -match ".*($UseCase).*"}
                    $appinsightName = $dispatchappInsightName | Where-Object {$_ -match ".*($UseCase).*"}
                    
                    Write-Host "[command]---------------------------------------------------------------------------------"
                    Write-Host "[command] UseCase Name       : $UseCase"
                    Write-Host "[command] Namespace Name     : $namespace"
                    Write-Host "[command] ResourceGroup Name : $resourcegroupName"
                    Write-Host "[command] Appinsight Name    : $appinsightName"
                    Write-Host "[command]---------------------------------------------------------------------------------"
                    
                    # Retrieve ACR access token and login to Helm registry
                    $helmChartversion = getHelmChartVersion -configPath $configPath -Customer $customerName -dispatchuseCase $UseCase

                    if($helmChartversion)
                    {
                        foreach ($version in $helmChartversion) 
                        {
                            # Revert "_" back to "+" for Helm pull
                            $originalVersion = $version -replace '_', '+'

                            # Define temporary directory to download Helm charts
                            $tempDir = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString())) -Force

                            try {
                                $HelmChartName= "oncalldispatch"
                                # Pull the Helm chart
                                $helmPullResult = helm pull oci://$ACRName/helm/$HelmChartName --version $originalVersion --destination $tempDir.FullName *> $null 2>&1
                                if ($LASTEXITCODE) {
                                    python $pythonScriptPath log_message --message "Failed to pull Helm chart version" --log_type "ERROR" 
                                    throw "Failed to pull Helm chart version $version."                  
                                    continue
                                }
                                Write-Host "##[section]Helm chart version $version pulled successfully."

				                $deployedVersion = helm list --namespace $namespace| awk '{print $9, $10}' | tail -n +2

                                if($deployedVersion){
                                    $oncalldispatch = $deployedVersion | Where-Object { $_ -like "oncalldispatch*" } | Select-Object -First 1
                                    $oncalldispatchversion = $oncalldispatch -split '-' | Select-Object -Last 1
                                    $oncalldispatchversion = $oncalldispatchversion -split ' ' | Select-Object -First 1
                                    $oncalldispatchversion = $oncalldispatchversion -replace '\+', '_'
                                    
                                }

                                if($version -eq $oncalldispatchversion){
                                    python $pythonScriptPath log_message --message "Helm chart version Matched With Deployed Version" --log_type "INFO" 
                                    Write-Host "[section]Matched: Helm version: $version  |  OnCallDispatch: $oncalldispatchversion"
                                }
                                else{
                                    Write-Host "[error]Not Matched: helm version: $version  |  OnCallDispatch: $oncalldispatchversion"
                                    python $pythonScriptPath log_message --message "Helm chart version Not Matched With Deployed Version" --log_type "ERROR" 
                                    throw "Dispatch Helm version $oncalldispatchversion in customer config does not matched with deployed version $version"
                                }
                                # Extract the Helm chart
                                $chartTgzPath = Join-Path -Path $tempDir.FullName -ChildPath "${HelmChartName}-${originalVersion}.tgz"
                                if (-not (Test-Path $chartTgzPath)) {
                                    Write-Error "Helm chart tgz file for version $version not found: $chartTgzPath"
                                    python $pythonScriptPath log_message --message "Helm chart tgz file for version $version not found" --log_type "ERROR"  
                                    continue
                                }

                                # Create directory to extract Helm chart files
                                $chartExtractPath = Join-Path -Path $tempDir.FullName -ChildPath "helmchartfiles"
                                New-Item -ItemType Directory -Path $chartExtractPath -Force | Out-Null

                                # Extract Helm chart files
                                tar -xzvf $chartTgzPath -C $chartExtractPath *> $null 2>&1
                                # Verify if the namespace exists
                                
                                $verifyNamespace = kubectl get namespace $namespace -o name
                                if (-not $verifyNamespace) {
                                    python $pythonScriptPath log_message --message "Namespace $namespace not found." --log_type "ERROR"
                                    throw "Namespace $namespace not found."
                                }

                                # Fetch Helm values from the specified namespace
                                $helmValuesYaml = helm get values oncall-dispatch -n $namespace --all
                                $helmValues = $helmValuesYaml | ConvertFrom-Yaml

                                # Initialize the results hashtable
                                $results = @{}
                                $extractedPodNames = [ref]@{}
                                ExtractPodNames -data $helmValues -results $extractedPodNames

                                foreach ($key in $extractedPodNames.Value.Keys) {
                                    $results[$key] = $extractedPodNames.Value[$key]
                                }

                                $extractedPodNames = [hashtable]::Synchronized(@{})
                                ExtractPodNames -data $helmValues -results ([ref]$extractedPodNames)

                                # Call getPodsByHelmChartPath function to retrieve YAML files and check for appinsights.secrets keyword
                                $podresults = getPodsByHelmChartPath -HelmChartPath $chartExtractPath -YamlFileNamePattern1 $yamlFilePattern1 -YamlFileNamePattern2 $yamlFilePattern2 -ExtractedPodNames $extractedPodNames -HelmValuesYaml $helmValues
                                $totalReplicas = ($podresults.Values | Measure-Object -Sum).Sum
                                Write-Host "##[group]"
                                Write-Host "Expected Pods Which are Configured to Send Logs to AI: $totalReplicas "
                                Write-Host "[command]---------------------------------------------------------------------------------"
                                Write-Host "Usage: Podname = ReplicaCount"
                                $podresults.GetEnumerator() | ForEach-Object {Write-Output "[command]$($_.Key) = $($_.Value)"} | Sort-Object
                                Write-Host "##[endgroup]"

                                #getrunning pods will get all the running pods from the customer namespace                    
                                $runningPods = getRunningPods -dispatchNamespace $namespace

                                #getAiPods will get all pods from the AI
                                $getAiPods = getAiPods -appinsightName $appinsightName -resourceGroup $resourcegroupName
                                 
                                if($runningPods -and $getAiPods){
                                    #function to compare the list of running pods with deployed pods to filter out the not running pods
                                    $getcomparePods = getCompareBaseRunningPods -shouldbePods $podresults -runningPods $runningPods
                                    
                                    #function to verify running pods with and AI
                                    $getfPods = getFinalPods -comparePods $getcomparePods[0] -aiPods $getAiPods -totalpods $totalPods
                                    
                                    if($getfPods -and $getcomparePods)
                                    {
                                        $sendingLogs = $getfPods[0]
                                        $notSendingLogs = ($getfPods[1]) + ($getcomparePods[2])
                                        $nRunningState = $getcomparePods[2]
                                        $nAiState = $getfPods[1]
                                        Write-Host "[command]---------------------------------------------------------------------------------"
                                        Write-Host "* TOTAL PODS WHICH ARE CONFIGURED TO SEND LOGS TO AI  :  $totalReplicas"
                                        Write-Host "[section]* TOTAL PODS WHICH ARE SENDING LOGS TO AI             : "($getfPods[0]) / $totalReplicas""
                                        Write-Host "[command]* TOTAL PODS WHICH ARE NOT SENDING LOGS TO AI         : "($getfPods[1] + $getcomparePods[2]) / $totalReplicas""
                                        Write-Host "[command]       ! TOTAL PODS WHICH ARE NOT IN RUNNING STATE    : "$getcomparePods[2]
                                        Write-Host "[command]       ! TOTAL PODS WHICH ARE IN RUNNING & NOT IN AI  : "$getfPods[1]""
                                        Write-Host "[command]---------------------------------------------------------------------------------"

                                        python $pythonScriptPath log_message --message "* TOTAL PODS WHICH ARE CONFIGURED TO SEND LOGS TO AI  :  $totalReplicas" --log_type "INFO"
                                        python $pythonScriptPath log_message --message "* TOTAL PODS WHICH ARE SENDING LOGS TO AI  :  $sendingLogs" --log_type "INFO"
                                        python $pythonScriptPath log_message --message "* TOTAL PODS WHICH ARE NOT SENDING LOGS TO AI     :  $notSendingLogs" --log_type "INFO"
                                    }
                                    else
                                    {
                                        throw 
                                    }                                    
                                }
                                else{
                                    throw
                                }
                            }
                            catch{
                                Write-Warning "Exception Found: $_"
                                $failedCount++
                                $failedUseCases += $UseCase
                                python $pythonScriptPath log_message --message "Exception Found: $_" --log_type "ERROR"

                            }
                            finally {
                                # Clean up the temporary directory
                                Remove-Item -Path $tempDir.FullName -Recurse -Force
                            }
                        }
                    }
                    else{
                        python $pythonScriptPath log_message --message "Exception Found: Helm Pull Failed" --log_type "ERROR"
                        throw "[warning] $UseCase Helm Pull Failed"
                    }
                }
            }
            catch{
                $failedUseCases += @("$UseCase", " ")
                Write-Warning "UseCase: $UseCase Failed with $_"
                python $pythonScriptPath log_message --message "UseCase: $UseCase Failed with $_" --log_type "ERROR"
                $failedCount++
            }
            Write-Host "[endgroup]"
            $currentindex++
            Stop-Transcript > $null 2>&1
            cleanFileContent -inputFilePath $logFile -outputFilePath $logFile
        }
        if($currentindex -eq $totalindex){
            if($failedCount -gt 0){
                python $pythonScriptPath log_message --message "Application Insights Log Validation Task Failed: $failedCount UseCases Failed - $failedUseCases" --log_type "ERROR"
                Write-Host "[error]Application Insights Log Validation Task Failed: $failedCount UseCases Failed - $failedUseCases"
                python $pythonScriptPath log_task_end --task_name "AppInsight Pod Log Validation" 
                exit 1
            }
            else{
                Write-Host "[section]All Usecases Iterated $currentindex/$totalindex"
                python $pythonScriptPath log_message --message "All Usecases Iterated" --log_type "INFO"
                python $pythonScriptPath log_task_end --task_name "AppInsight Pod Log Validation"
                if($getcomparePods[2] -ne 0 -or $getfPods[1] -ne 0 ){
                    Write-Host "[error] EXITING SCRIPT WITH EXIT 1, REASON: FEW PODS ARE NOT INGESTING LOGS/NOT IN RUNNING STATE"
                    exit 1
                }
                else{
                    Write-Host "[section]ALL PODS ARE CONFIGURED TO SEND LOGS TO AI"
                    exit 0
                }
                
            }
        }
    }
    else{
        Write-Warning "No Usecases Found"
        python $pythonScriptPath log_message --message "No UseCase Found" --log_type "INFO"
        python $pythonScriptPath log_task_end --task_name "AppInsight Pod Log Validation"
    }
}
catch {
    Write-Error "Failed to retrieve ACR access token or login to Helm registry. $_"
    python $pythonScriptPath log_message --message "Failed to retrieve ACR access token or login to Helm registry." --log_type "ERROR"
    python $pythonScriptPath log_task_end --task_name "AppInsight Pod Log Validation"
    exit 1
}