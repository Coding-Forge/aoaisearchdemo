Write-Host ""
Write-Host "Loading azd .env file from current environment"
Write-Host ""

$output = azd env get-values

foreach ($line in $output) {
  $name, $value = $line.Split("=")
  $value = $value -replace '^\"|\"$'
  [Environment]::SetEnvironmentVariable($name, $value)
}

$keyVaultName = $env:AZURE_KEYVAULT_NAME
$tenant_id = $env:AZURE_TENANT_ID
$subscription_id = $env:AZURE_SUBSCRIPTION_ID
$openai_api_key=$env:AZURE_OPENAI_API_KEY
$openai_service=$env:AZURE_OPENAI_SERVICE
$search_index=$env:AZURE_SEARCH_INDEX
$skip_vectorization=$env:SEARCH_SKIP_VECTORIZATION
$dimensions=$env:AZURE_OPENAI_EMBEDDINGS_DIMENSIONS

Write-Host ""
Write-Host "Fetching secrets from Azure Key Vault '$keyVaultName'..."
Write-Host "This is the tenant ID: $tenant_id"
write-host "This is the subscription ID: $subscription_id"
Write-Host "This is the dimensions: $dimensions"
Write-Host ""


Connect-AzAccount -Tenant $tenant_id -SubscriptionId $subscription_id

# Install required Azure modules if not already installed
if (-not (Get-Module -Name Az.KeyVault -ListAvailable)) {
  Install-Module -Name Az.KeyVault -Force -AllowClobber
}

# Set the environment variables
$secrets = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "*"
foreach ($secret in $secrets) {
  $name = $secret.Name
  $value = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $name -AsPlainText
  $updatedName = $name.Replace("-", "_")
  [Environment]::SetEnvironmentVariable($updatedName, $value)
}

if ($LastExitCode -ne 0) {
  Write-Host ""
  Write-Host "Fetching secrets from Azure KeyVault failed with non-zero exit code $LastExitCode."
  Write-Host ""
  exit $LastExitCode
}

# Disconnect from Azure
Disconnect-AzAccount

Write-Host ""
Write-Host "Environment variables set."
Write-Host ""

Write-Host ""
Write-Host "Installing post-deployment dependencies..."
Write-Host ""
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
  # fallback to python3 if python not found
  $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
}
Start-Process -FilePath ($pythonCmd).Source -ArgumentList "-m venv ./scripts/.venv" -Wait -NoNewWindow

$venvPythonPath = "./scripts/.venv/Scripts/python.exe"
if (Test-Path -Path "/usr") {
  # fallback to Linux venv path
  $venvPythonPath = "./scripts/.venv/bin/python"
}

$process = Start-Process -FilePath $venvPythonPath -ArgumentList "-m pip install -r ./scripts/requirements.txt" -Wait -NoNewWindow -PassThru

if ($process.ExitCode -ne 0) {
  Write-Host ""
  Write-Warning "Installing post-deployment dependencies failed with non-zero exit code $LastExitCode."
  Write-Host ""
  exit $process.ExitCode
}

Write-Host ""
Write-Host 'Running "prepdocs.py"...'
Write-Host ""
$predocsArguments = "./scripts/indexing/prepdocs.py", "./data/surface_device_documentation/",
  "--storageaccount", $env:AZURE_STORAGE_ACCOUNT,
  "--container", $env:AZURE_STORAGE_CONTAINER, 
  "--searchservice", $env:AZURE_SEARCH_SERVICE, 
  "--index", $search_index, 
  "--formrecognizerservice", $env:AZURE_FORMRECOGNIZER_SERVICE,
  "--skipvectorization", $skip_vectorization,
  "--openAIService", $openai_service,
  "--openaikey", $openai_api_key,
  "--openaiengine", $env:AZURE_OPENAI_EMBEDDINGS_DEPLOYMENT,
  "--openaitokenlimit", $env:AZURE_OPENAI_EMBEDDINGS_TOKEN_LIMIT,
  "--openaidimensions", $dimensions,
  "-v"
  

$process = Start-Process -FilePath $venvPythonPath -ArgumentList $predocsArguments -Wait -NoNewWindow -PassThru

if ($process.ExitCode -ne 0) {
  Write-Host ""
  Write-Warning "Document ingestion into search index failed with non-zero exit code $LastExitCode. This process must run successfully at least once for Cognitive Search to behave properly."
  Write-Host ""
}

Write-Host ""
Write-Host 'Running "prepopulate.py"...'
Write-Host ""
$prepoulateArguments = "./scripts/prepopulate/prepopulate.py",
  "--entitiespath", "./scripts/prepopulate/entries/entities.yaml",
  "--permissionspath", "./scripts/prepopulate/entries/permissions.yaml",
  "--cosmosdbendpoint", $env:AZURE_COSMOS_ENDPOINT,
  "--cosmosdbname", $env:AZURE_COSMOS_DB_NAME,
  "--cosmosdbentitiescontainername", $env:AZURE_COSMOS_DB_ENTITIES_CONTAINER_NAME,
  "--cosmosdbpermissionscontainername", $env:AZURE_COSMOS_DB_PERMISSIONS_CONTAINER_NAME,
  "-v"
$process = Start-Process -FilePath $venvPythonPath -ArgumentList $prepoulateArguments -Wait -NoNewWindow -PassThru

if ($process.ExitCode -ne 0) {
  Write-Host ""
  Write-Warning "Prepopulation of necessary Cosmos DB tables failed with non-zero exit code $LastExitCode. This process must run successfully at least once for the sample to run properly."
  Write-Host ""
}

Write-Host ""
Write-Host 'Running "populate_sql.py"...'
Write-Host ""
$populatesqlArguments = "./scripts/prepopulate/populate_sql.py",
  "--sqlconnectionstring", "`"$env:SQL_CONNECTION_STRING`"",
  "--subscriptionid", "$env:AZURE_SUBSCRIPTION_ID",
  "--resourcegroup", "$env:AZURE_RESOURCE_GROUP",
  "--servername", "$env:SQL_SERVER_NAME",
  "-v"

$process = Start-Process -FilePath $venvPythonPath -ArgumentList $populatesqlArguments -Wait -NoNewWindow -PassThru

if ($process.ExitCode -ne 0) {
  Write-Host ""
  Write-Warning "Prepopulation of necessary SQL tables failed with non-zero exit code $LastExitCode. This process must run successfully at least once for the sample to run properly."
  Write-Host ""
}
